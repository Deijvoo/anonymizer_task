#!/usr/bin/env bash
set -euo pipefail

# Verify Prometheus is scraping Kafka JMX exporter and target is up.

PROM=${PROM:-http://localhost:9090}

echo "[itest-prom] waiting for Prometheus..."
deadline=$(( $(date +%s) + 60 ))
until curl -fsS "$PROM/-/ready" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "[itest-prom] Prometheus not ready"; exit 1; };
  sleep 2
done

echo "[itest-prom] checking kafka target up metric (sum)..."
# Query Prometheus for sum(up{job="kafka"}) and parse numeric without jq
raw=$(docker compose exec -T prometheus wget -qO- "http://localhost:9090/api/v1/query?query=sum(up%7Bjob%3D%22kafka%22%7D)" 2>/dev/null || curl -fsS "$PROM/api/v1/query?query=sum(up%7Bjob%3D%22kafka%22%7D)" || true)
# Extract the numeric value: tolerate float timestamps
val=$(printf "%s" "$raw" | sed -n 's/.*"value":\[[0-9][0-9]*\(\.[0-9][0-9]*\)\?,"\([0-9][0-9]*\(\.[0-9][0-9]*\)\?\)".*/\2/p')
echo "sum(up{job=\\\"kafka\\\"})=$val"

if [ -n "${val:-}" ] && awk "BEGIN{exit !($val>=1)}"; then
  echo "[itest-prom] OK: Prometheus reports kafka target up"
  exit 0
fi

echo "[itest-prom] FAILED: Prometheus does not report kafka target up"
exit 1

