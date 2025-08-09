CREATE DATABASE IF NOT EXISTS logs;

CREATE TABLE IF NOT EXISTS logs.http_log
(
  `timestamp` DateTime,
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

