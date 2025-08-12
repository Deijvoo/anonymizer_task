## REPORT (from-scratch narrative)

### Executive summary
This repository implements an ETL pipeline for HTTP access logs with at-least-once delivery semantics:
- Produce binary log records (Cap'n Proto) into Kafka (`http_log`).
- Consume in a C++ anonymizer that masks IPs and batches JSONEachRow inserts to ClickHouse via an Nginx proxy limited to 1 request/minute.
- Observe the system in Grafana (ClickHouse panels for traffic, Prometheus panels for Kafka broker) and verify health with tests (unit, integration, E2E).

The code favors correctness and robustness over peak throughput, given the 1 req/min insertion constraint. Backoff on 503 is explicit and idempotent effects are documented.

### Why this design
- Simplicity at the edges: Kafka for decoupling, ClickHouse for analytics, HTTP insert for operational ease, proxy for rate limiting.
- Explicit delivery semantics: manual commits in Kafka after a successful insert → at-least-once without hidden magic.
- Operability: deterministic flush timer, visible logs, clear error handling, small surface area to debug.

What I considered and (for now) rejected:
- Exactly-once end-to-end: possible with transactional Kafka + idempotent producer and dedup in ClickHouse (ReplacingMergeTree or `deduplicate_blocks=1`), but overkill for this task and needs much more testing.
- Direct CH driver/binary protocol: HTTP is good enough, easier to operate behind the rate-limiting proxy.
- Per-row inserts: would satisfy proxy limit but terrible for CH performance; batched JSONEachRow is the right trade-off.

### Architecture (arrow-by-arrow, mirroring `anonymizer.png`)
1) Logs → Kafka (`http_log`)
   - Extract step. The provided producer serializes records using Cap'n Proto. Backpressure is natural: if broker is down or slow, producer retries and rate can be tuned via `KAFKA_PRODUCER_DELAY_MS`.
   - Why Kafka: durability, replay, and consumer group scaling without coupling producer to ClickHouse availability.

2) Kafka → Anonymizer (C++)
   - Transform step. The consumer decodes Cap'n Proto, masks IPs (last octet → `X`), builds a JSON line, and accumulates rows in memory.
   - Manual offset management: `enable.auto.commit=false` and commit only after a successful batch insert → at-least-once.
   - Graceful shutdown: signal handlers and clean exit to avoid partial commits.

3) Anonymizer → Nginx proxy (1 req/min) → ClickHouse HTTP
   - Load step. Batched `JSONEachRow` insert via `libcurl`.
   - Rate limit: the proxy enforces 1 request/min. On HTTP 503, the anonymizer backs off to the next allowed window (`next_allowed_send`) instead of hammering the proxy.
   - Why proxy: isolates ClickHouse from client behavior and centralizes rate policy. Could also host auth/TLS here.

4) Kafka → JMX Exporter → Prometheus → Grafana
   - Broker health: controller count, under-replicated partitions, request handler idle %, I/O rates.
   - Our Prometheus job is `kafka` scraping `jmx-kafka:5556`.

5) ClickHouse → Grafana (HTTP Logs)
   - Visualize traffic: rows/min, bytes/min, RPS, p95 latencies, status mix, top URLs. We deliver two ClickHouse dashboards in JSON.

6) Kafka → Kafka‑UI (optional)
   - Convenience UI to inspect topics, consumer groups, offsets and lag while testing.

### Delivery semantics and correctness
- At-least-once: commits follow successful inserts. A crash after insert but before commit causes duplicates on replay — expected and documented.
- Dedup strategies (if needed later):
  - ClickHouse ReplacingMergeTree keyed by a stable identity (e.g., `(topic, partition, offset)`), or
  - `deduplicate_blocks=1` on insert path with consistent block hashes, or
  - Persist a dedup token in the JSON and aggregate through a materialized view.

### Failure modes and handling
- ClickHouse proxy 503 (rate limit): wait until the next window, then retry; we explicitly track `next_allowed_send`.
- Kafka topic missing: producer creates or we create via `kafka-topics`; consumer logs a clear error.
- Network hiccups/timeouts: `libcurl` connect and request timeouts with clear messages.
- Idle topic: time-based flush still occurs via a timer path checked each loop iteration.

### Performance
- Insert cadence: ~60–70s between flushes (window + network + CH). This dominates end-to-end latency.
- Throughput: limited by 1 req/min; within that, large batched inserts are efficient for CH.
- Observability: Grafana ClickHouse panels show rows/min, bytes/min, RPS; Kafka panels show request idle %, messages/sec.

Scaling paths
- Increase proxy rate (e.g., 60 req/min) and switch to sub-minute batching.
- Horizontalize: run multiple anonymizer instances in the same consumer group (increase Kafka partitions). Shard by key (e.g., `resource_id % N`) and give each instance its own proxy lane (or time‑offset the 1 req/min slots) → true parallel inserts without a buffer.
- Kafka: increase partitions and run more consumers in the same group (while respecting proxy lanes).
- ClickHouse: move to Replicated/Distributed tables when a single node becomes the bottleneck.

### Maintainability and code choices
- Small, explicit code in C++17; helpers split into `src/util.{h,cpp}` for testability.
- Clear control flow: early returns, explicit error paths, no implicit auto-commits.
- Minimal dependencies: `librdkafka++`, `capnp`, `curl`, `spdlog`.

### Security considerations
- IP masking: last IPv4 octet masked. For IPv6 or stricter privacy, use a cryptographic prefix-preserving hash with salt rotation.
- Transport: the demo runs plain HTTP inside a compose network. For production, terminate TLS at the proxy; restrict ClickHouse ports to the internal network.
- Secrets: environment variables for credentials; in production, use Docker secrets or a vault.

### Alternatives considered
- Exactly-once-ish: Kafka transactions + idempotent producers; ClickHouse dedup on insert. Higher complexity; skipped for task scope.
- Buffer table in ClickHouse: insert fast into a Buffer engine, auto-flush to MergeTree. Could replace the proxy if policy allows.
- Direct Kafka → ClickHouse (Kafka engine in CH): reduces C++ logic, but sacrifices custom anonymization unless pushed upstream.

### What is optimal vs. not
- Optimal here: batched JSONEachRow, explicit backoff, manual commits, simple deploy.
- Not optimal for high TPS: 1 req/min proxy is a hard cap; if SLOs require lower latency, raise the rate or shard lanes.

### Production hardening (what I'd add before go‑live)
- Soak tests with realistic rates; chaos tests (random restarts), and automated SLO dashboards (flush duration, retries, lag).
- Exactly-once-ish dedup if consumers require it.
- TLS + auth on the proxy; ClickHouse users with minimum privileges.
- Structured metrics from the anonymizer (Prometheus textfile or native expo) and alerts.

### What I got stuck on and how I solved it
- Docker daemon/WSL issues → restart scripts; ensured compose uses project root as context.
- Cap'n Proto headers missing → generate includes added to CMake; include path fixed.
- `librdkafka++` runtime missing → install `librdkafka++1` in runtime image.
- Kafka topic not found → ensure producer creates or create via CLI.
- ClickHouse `HTTP 400` parse error → fixed JSON formatting and numeric timestamp.
- Grafana datasource glitches and port conflicts → use access `proxy`, correct URLs, and moved Grafana to 3001 on host.
- Flush timing on idle topic → time-based flush executed every loop iteration, not only on new messages.
- Rate-limit storms (many 503) → consolidated backoff and removed duplicate flush path.

### Time investment (rough)
- Research/reading: ~2–3h
- Core anonymizer implementation + fixes: ~5–6h
- Docker/compose integration + build fixes: ~3–4h
- Grafana/Prometheus setup + dashboards: ~2–3h
- Tests (unit, integ, E2E) + stabilization: ~2h
- Documentation/report: ~1–2h

### How to run (quick)
- Bring up stack: `docker compose up -d`
- Grafana: http://localhost:3001 (admin/kafka)
- (Optional) Recreate CH schema (auto-init via sidecar is included): `docker compose up -d clickhouse-init`

### Tests
- Unit (no infra): `cmake -S . -B build && cmake --build build -j && ctest --test-dir build -V`
- Integration (needs stack):
  - Kafka → anonymizer: `bash tests/integration/kafka_to_anonymizer.sh`
  - Anonymizer → ClickHouse: `bash tests/integration/anonymizer_to_clickhouse.sh`
- E2E (full): `bash tests/e2e/test_full.sh`

### Real data snapshot (from running system)
- Total rows: 4,448
- Last event time: 2025-08-12 19:15:59
- Rows/min (last ~15m):
  - 19:04 3, 19:05 4, 19:06 3, 19:07 8, 19:09 2, 19:10 3, 19:11 2, 19:12 2, 19:13 2, 19:14 2, 19:15 1
- Bytes/min (last ~15m):
  - 19:04 3,827,646; 19:05 4,300,961; 19:06 1,961,951; 19:07 10,099,096; 19:08 2,027,517; 19:09 1,552,338; 19:11 1,611,729; 19:12 693,496; 19:13 1,692,950; 19:14 1,398,340; 19:15 2,008,706
- Status distribution (last 1h):
  - 400:149, 500:149, 200:147, 301:147, 504:146, 404:141, 502:132, 403:111
- Top URLs (last 1h, cnt/bytes): examples show heavy media assets (~2–5 MB per hit)
- p95 request_time_milli (last ~15m):
  - 19:04 1898; 19:05 17124.4; 19:06 21115.55; 19:07 26934.85; 19:08 20503.65; 19:09 17174; 19:10 23104.9; 19:11 16323.3; 19:12 25270.45; 19:13 28236.25; 19:14 7904.25; 19:15 11873; 19:16 23369.75

### Dashboards and screenshots
- ClickHouse dashboards: `grafana/dashboards/http_log_overview.json`, `grafana/dashboards/http_logs_dashboard.json`
- Prometheus/Kafka: `grafana/dashboards/` (broker overview, replication, performance, JMX, topics)
- Screenshot: add a single full dashboard PNG at `report_assets/dashboard.png`.

### Appendix: SQL (DDL)
`etc/clickhouse/01_schema.sql` creates:
- `logs.http_log` (MergeTree) with partition by day and ordered by `(timestamp, resource_id, response_status, cache_status, remote_addr)`
- `logs.http_log_agg` (SummingMergeTree) + MV `logs.http_log_mv` for pre-aggregations

Note: Chaos testing (random restarts of broker/ClickHouse/proxy/anonymizer during sustained ingest) is planned before production rollout. Scope: verify continuous ingest, quantify duplicates under at‑least‑once, and validate automated recovery. Not executed in this submission.

### Tests
- Unit (native, no infra required): IP anonymization, JSON escaping, join, env fallback; Cap'n Proto round‑trip
  - `cmake -S . -B build && cmake --build build -j && ctest --test-dir build -V`
- Integration (requires stack):
  - Kafka → anonymizer: `bash tests/integration/kafka_to_anonymizer.sh`
  - Anonymizer → ClickHouse: `bash tests/integration/anonymizer_to_clickhouse.sh`
- E2E (full path, tolerant to proxy backoff):
  - `bash tests/e2e/test_full.sh`

### Dashboards
- ClickHouse: `grafana/dashboards/http_log_overview.json`, `grafana/dashboards/http_logs_dashboard.json`
- Kafka/Prometheus: existing dashboards in `grafana/dashboards/` (cluster health, replication, performance, JMX, topics)
