#!/usr/bin/env bash
set -euo pipefail

# Print E2E latency quantiles for the last 1h from ClickHouse.
# Uses ingested_at - timestamp if available, else falls back to now() - timestamp.

CH=${CH:-http://localhost:8123}
WINDOW=${WINDOW:-1 HOUR}

echo "[latency] probing schema for ingested_at..."
has_col=$(curl -fsS "$CH/?query=SELECT%20count()%20FROM%20system.columns%20WHERE%20database%3D'logs'%20AND%20table%3D'http_log'%20AND%20name%3D'ingested_at'" || echo 0)
if [ "${has_col:-0}" -ge 1 ]; then
  echo "[latency] using ingested_at - timestamp"
  q="SELECT quantileExact(0.5)(ingested_at - timestamp) AS p50_s, quantileExact(0.9)(ingested_at - timestamp) AS p90_s, quantileExact(0.99)(ingested_at - timestamp) AS p99_s FROM logs.http_log WHERE ingested_at > now() - INTERVAL $WINDOW";
else
  echo "[latency] fallback now() - timestamp (approx)"
  q="SELECT quantileExact(0.5)(now() - timestamp) AS p50_s, quantileExact(0.9)(now() - timestamp) AS p90_s, quantileExact(0.99)(now() - timestamp) AS p99_s FROM logs.http_log WHERE timestamp > now() - INTERVAL $WINDOW";
fi

urlenc() {
  # poor-man urlencode for spaces and punctuation used
  printf '%s' "$1" | sed -e 's/ /%20/g' -e 's/,/%2C/g' -e 's/\*/%2A/g' -e 's/\//%2F/g' -e 's/\?/%3F/g' -e 's/:/%3A/g' -e 's/(/%28/g' -e 's/)/%29/g' -e 's/</%3C/g' -e 's/>/%3E/g' -e 's/\n/%0A/g'
}

echo "[latency] running quantiles for last $WINDOW ..."
curl -fsS "$CH/?query=$(urlenc "$q")" | cat

