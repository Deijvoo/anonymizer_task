CREATE DATABASE IF NOT EXISTS logs;

CREATE TABLE IF NOT EXISTS logs.http_log
(
  `timestamp` DateTime,
  `ingested_at` DateTime DEFAULT now(),
  `resource_id` UInt64,
  `bytes_sent` UInt64,
  `request_time_milli` UInt64,
  `response_status` UInt16,
  `cache_status` LowCardinality(String),
  `method` LowCardinality(String),
  `remote_addr` String,
  `url` String
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (timestamp, resource_id, response_status, cache_status, remote_addr);

-- Ensure column exists even if table pre-existed
ALTER TABLE logs.http_log ADD COLUMN IF NOT EXISTS `ingested_at` DateTime DEFAULT now();

CREATE TABLE IF NOT EXISTS logs.http_log_agg
(
  `resource_id` UInt64,
  `response_status` UInt16,
  `cache_status` LowCardinality(String),
  `remote_addr` String,
  `bytes_sent_sum` UInt64,
  `requests_count` UInt64
)
ENGINE = SummingMergeTree
ORDER BY (resource_id, response_status, cache_status, remote_addr);

CREATE MATERIALIZED VIEW IF NOT EXISTS logs.http_log_mv
TO logs.http_log_agg AS
SELECT
  resource_id,
  response_status,
  cache_status,
  remote_addr,
  sum(bytes_sent) AS bytes_sent_sum,
  count() AS requests_count
FROM logs.http_log
GROUP BY resource_id, response_status, cache_status, remote_addr;

-- ---------------------------------------------------------------------------
-- Latency aggregation (per-minute p50/p90/p99 over E2E latency in seconds)
-- Stores TDigest state for efficient percentile queries.

CREATE TABLE IF NOT EXISTS logs.http_log_latency_agg
(
  `bucket` DateTime,
  `q_state` AggregateFunction(quantilesTDigest(0.5, 0.9, 0.99), Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(bucket)
ORDER BY bucket;

CREATE MATERIALIZED VIEW IF NOT EXISTS logs.http_log_latency_mv
TO logs.http_log_latency_agg AS
SELECT
  toStartOfMinute(ingested_at) AS bucket,
  quantilesTDigestState(0.5, 0.9, 0.99)(toFloat64(ingested_at - timestamp)) AS q_state
FROM logs.http_log
WHERE (ingested_at - timestamp) BETWEEN 0 AND 7200
GROUP BY bucket;

-- Dimensional latency aggregation (per-minute, by resource_id and response_status)
CREATE TABLE IF NOT EXISTS logs.http_log_latency_agg_dim
(
  `bucket` DateTime,
  `resource_id` UInt64,
  `response_status` UInt16,
  `q_state` AggregateFunction(quantilesTDigest(0.5, 0.9, 0.99), Float64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(bucket)
ORDER BY (bucket, resource_id, response_status);

CREATE MATERIALIZED VIEW IF NOT EXISTS logs.http_log_latency_mv_dim
TO logs.http_log_latency_agg_dim AS
SELECT
  toStartOfMinute(ingested_at) AS bucket,
  resource_id,
  response_status,
  quantilesTDigestState(0.5, 0.9, 0.99)(toFloat64(ingested_at - timestamp)) AS q_state
FROM logs.http_log
WHERE (ingested_at - timestamp) BETWEEN 0 AND 7200
GROUP BY bucket, resource_id, response_status;

