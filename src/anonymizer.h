#pragma once

#include <chrono>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
#include <librdkafka/rdkafkacpp.h>
#include <spdlog/spdlog.h>
#include "util.h"

// Helpers are declared in `util.h`

// ---------------------------------------------------------------------------
// Kafka consumer (RAII wrapper)
class KafkaConsumer {
public:
    KafkaConsumer();
    ~KafkaConsumer();

    /// Blocks for at most `timeout` and returns a message (nullptr on timeout).
    std::unique_ptr<RdKafka::Message> poll(std::chrono::milliseconds timeout);

    /// Synchronous commit for given offsets (typically after flush).
    void commit(std::vector<RdKafka::TopicPartition*>& partitions);

    /// Synchronous commit current offsets for assigned partitions.
    void commitCurrent();

private:
    std::unique_ptr<RdKafka::KafkaConsumer> consumer_;
};

// ---------------------------------------------------------------------------
// ClickHouse HTTP sink
class ClickHouseSink {
public:
    ClickHouseSink();
    ~ClickHouseSink();

    void send(const std::vector<std::string>& rows);
private:
    std::string url_{};
};

// ---------------------------------------------------------------------------
// Main loop
int run_anonymizer(int argc, char* argv[]);
