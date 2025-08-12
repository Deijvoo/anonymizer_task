#include "anonymizer.h"
#include <capnp/serialize-packed.h>
#include "http_log.capnp.h"
#include <curl/curl.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <cstring>
#include <kj/array.h>
#include <thread>
#include <atomic>
#include <csignal>
#include <cstdlib>
#include <cstdio>
#include <sstream>

static std::atomic<bool> g_running{true};
static void handle_signal(int) {
    g_running.store(false);
}


// Helpers moved to src/util.cpp

// ---------------------------------------------------------------------------
// KafkaConsumer

KafkaConsumer::KafkaConsumer() {
    std::string err;

    std::unique_ptr<RdKafka::Conf> conf(RdKafka::Conf::create(RdKafka::Conf::CONF_GLOBAL));
    {
        std::string brokers = getEnvOrDefault("KAFKA_BROKERS", KAFKA_BROKER);
        conf->set("bootstrap.servers", brokers, err);
    }
    {
        std::string groupId = getEnvOrDefault("KAFKA_GROUP_ID", KAFKA_GROUP_ID_DEFAULT);
        conf->set("group.id", groupId, err);
    }
    conf->set("enable.auto.commit", "false", err);

    consumer_.reset(RdKafka::KafkaConsumer::create(conf.get(), err));
    if (!consumer_) {
        spdlog::critical("Kafka create failed: {}", err);
        throw std::runtime_error("Kafka create failed: " + err);
    }

    if (auto rc = consumer_->subscribe({KAFKA_TOPIC}); rc != RdKafka::ERR_NO_ERROR) {
        auto what = "Kafka subscribe: " + RdKafka::err2str(rc);
        spdlog::critical("{}", what);
        throw std::runtime_error(what);
    }

    spdlog::info("Kafka consumer subscribed to topic {}", KAFKA_TOPIC);
}

KafkaConsumer::~KafkaConsumer() {
    if (consumer_)
        consumer_->close();
}

std::unique_ptr<RdKafka::Message> KafkaConsumer::poll(std::chrono::milliseconds timeout) {
    return std::unique_ptr<RdKafka::Message>(consumer_->consume(static_cast<int>(timeout.count())));
}

void KafkaConsumer::commit(std::vector<RdKafka::TopicPartition*>& partitions) {
    if (!consumer_) return;
    auto err = consumer_->commitSync(partitions);
    if (err != RdKafka::ERR_NO_ERROR) {
        spdlog::error("Kafka commit failed: {}", RdKafka::err2str(err));
        throw std::runtime_error("Kafka commit failed: " + RdKafka::err2str(err));
    }
}

void KafkaConsumer::commitCurrent() {
    if (!consumer_) return;
    auto err = consumer_->commitSync();
    if (err != RdKafka::ERR_NO_ERROR) {
        spdlog::error("Kafka commit (current) failed: {}", RdKafka::err2str(err));
        throw std::runtime_error("Kafka commit failed: " + RdKafka::err2str(err));
    }
}

// ---------------------------------------------------------------------------
// ClickHouseSink

ClickHouseSink::ClickHouseSink() {
    curl_global_init(CURL_GLOBAL_ALL);
    url_ = getEnvOrDefault("CLICKHOUSE_URL", CLICKHOUSE_URL);
}

ClickHouseSink::~ClickHouseSink() {
    curl_global_cleanup();
}

void ClickHouseSink::send(const std::vector<std::string> &rows) {
    CURL *curl = curl_easy_init();
    if (!curl)
        throw std::runtime_error("curl init failed");

    std::string body = join_rows(rows);
    spdlog::debug("Sending batch of {} rows to ClickHouse", rows.size());

    // capture response body for diagnostics
    std::string responseBody;
    auto writeFn = +[](char* ptr, size_t size, size_t nmemb, void* userdata) -> size_t {
        auto* out = static_cast<std::string*>(userdata);
        out->append(ptr, size * nmemb);
        return size * nmemb;
    };

    curl_easy_setopt(curl, CURLOPT_URL, url_.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, body.size());
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 5000L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 30000L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeFn);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);

    if (auto rc = curl_easy_perform(curl); rc != CURLE_OK) {
        std::string msg = curl_easy_strerror(rc);
        curl_easy_cleanup(curl);
        spdlog::error("ClickHouse insert failed: {}", msg);
        throw std::runtime_error("ClickHouse insert failed: " + msg);
    }

    long httpCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);
    if (httpCode < 200 || httpCode >= 300) {
        std::string msg = "HTTP " + std::to_string(httpCode) + ": " + responseBody;
        curl_easy_cleanup(curl);
        spdlog::error("ClickHouse insert failed (status): {}", msg);
        throw std::runtime_error("ClickHouse insert failed: " + msg);
    }
    curl_easy_cleanup(curl);
}

// ---------------------------------------------------------------------------
// Main loop

int run_anonymizer(int /*argc*/, char* /*argv*/[]) {
    try {
        KafkaConsumer consumer;
        ClickHouseSink sink;

        std::vector<std::string> batch;
        batch.reserve(50'000);

        const std::size_t BATCH_MAX = []{
            std::string v = getEnvOrDefault("BATCH_MAX", "50000");
            return static_cast<std::size_t>(std::stoull(v));
        }();
        const auto FLUSH_EVERY = std::chrono::seconds([]{
            std::string v = getEnvOrDefault("FLUSH_SECONDS", "60");
            return static_cast<unsigned long long>(std::stoull(v));
        }());
        auto last_flush = std::chrono::steady_clock::now();
        // Avoid hammering proxy after 503. When rate-limited, we wait until next_allowed_send.
        auto next_allowed_send = std::chrono::steady_clock::time_point::min();

        // Graceful shutdown na SIGINT/SIGTERM
        std::signal(SIGINT, handle_signal);
        std::signal(SIGTERM, handle_signal);

        // helper to perform time-based flush even when idle
        auto try_flush = [&](std::chrono::steady_clock::time_point now) {
            if (batch.empty()) return;
            if (now < next_allowed_send) return; // still cooling down after 503
            if (now - last_flush < FLUSH_EVERY) return;
            try {
                sink.send(batch);
                spdlog::info("Flushed {} rows to ClickHouse", batch.size());
                batch.clear();
                last_flush = now;
                try { consumer.commitCurrent(); }
                catch (const std::exception &e) { spdlog::error("commit failed: {}", e.what()); }
            } catch (const std::exception &e) {
                spdlog::error("{}", e.what());
                const std::string msg = e.what();
                const auto now_err = std::chrono::steady_clock::now();
                if (msg.find("HTTP 503") != std::string::npos) {
                    // Respect 1 req/min: schedule next attempt at the next window edge
                    auto next_slot = last_flush + FLUSH_EVERY;
                    if (next_slot <= now_err) next_slot = now_err + FLUSH_EVERY;
                    next_allowed_send = next_slot;
                    auto wait = std::chrono::duration_cast<std::chrono::milliseconds>(next_slot - now_err);
                    spdlog::info("proxy 503 → backing off for {} ms until next slot", wait.count());
                    if (wait > std::chrono::milliseconds(0)) std::this_thread::sleep_for(wait);
                } else {
                    std::this_thread::sleep_for(std::chrono::seconds(5));
                }
            }
        };

        while (g_running.load()) {
            // time-based flush even if no messages arrive
            try_flush(std::chrono::steady_clock::now());

            auto msg = consumer.poll(std::chrono::milliseconds(100));
            if (!msg)
                continue; // timeout already handled by try_flush

            if (msg->err()) {
                if (msg->err() != RdKafka::ERR__TIMED_OUT)
                    spdlog::warn("Kafka error: {}", msg->errstr());
                continue;
            }

            // Cap'n Proto decode (aligned copy)
            std::size_t words = (msg->len() + sizeof(capnp::word) - 1) / sizeof(capnp::word);
            kj::Array<capnp::word> aligned = kj::heapArray<capnp::word>(words);
            std::memcpy(aligned.begin(), msg->payload(), msg->len());

            capnp::FlatArrayMessageReader reader(aligned);
            HttpLogRecord::Reader r = reader.getRoot<HttpLogRecord>();

            // anonymization + JSON build (optionally add identity for future deduplication)
            std::ostringstream oss;
            oss << R"({"timestamp":)" << (r.getTimestampEpochMilli() / 1000)
                << R"(,"resource_id":)" << r.getResourceId()
                << R"(,"bytes_sent":)" << r.getBytesSent()
                << R"(,"request_time_milli":)" << r.getRequestTimeMilli()
                << R"(,"response_status":)" << r.getResponseStatus()
                << R"(,"cache_status":")" << escape_json(r.getCacheStatus().cStr())
                << R"(","method":")" << escape_json(r.getMethod().cStr())
                << R"(","remote_addr":")" << escape_json(anonymize_ip(r.getRemoteAddr().cStr()))
                << R"(","url":")" << escape_json(r.getUrl().cStr())
                << R"("})";

            batch.emplace_back(std::move(oss).str());

            // If batch grew and we can't flush yet (1 req/min), wait for next flush window
            if (batch.size() >= BATCH_MAX) {
                auto now2 = std::chrono::steady_clock::now();
                if (now2 - last_flush < FLUSH_EVERY) {
                    auto wait = FLUSH_EVERY - (now2 - last_flush);
                    spdlog::info("Batch reached limit ({}). Waiting {} ms for next flush window...",
                                 batch.size(), std::chrono::duration_cast<std::chrono::milliseconds>(wait).count());
                    std::this_thread::sleep_for(wait);
                }
            }

            // main flush is handled by try_flush(now) at the start of the loop
        }

    } catch (const std::exception &e) {
        spdlog::critical("fatal: {}", e.what());
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// entry‑point

int main(int argc, char *argv[]) {
    auto console = spdlog::stdout_color_mt("console");
    spdlog::set_default_logger(console);
    spdlog::set_pattern("[%Y-%m-%d %H:%M:%S.%e] [%^%l%$] %v");
    spdlog::set_level(spdlog::level::info);

    spdlog::info("Starting anonymizer application");
    return run_anonymizer(argc, argv);
}
