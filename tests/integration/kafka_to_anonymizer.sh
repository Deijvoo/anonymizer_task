#!/usr/bin/env bash
set -euo pipefail

# Verifies Kafka -> anonymizer: produce a short burst, expect a flush in anonymizer logs.

echo "[itest] checking services running..."
docker compose ps >/dev/null

echo "[itest] starting a temporary fast producer..."
docker compose run -d --name temp-producer -e KAFKA_BOOTSTRAP_SERVERS=broker:29092 -e KAFKA_PRODUCER_DELAY_MS=100 http-log-kafka-producer >/dev/null

cleanup() {
  docker stop temp-producer >/dev/null 2>&1 || true
  docker rm temp-producer >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 10
cleanup || true

echo "[itest] waiting up to 90s for anonymizer flush..."
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  if docker logs anonymizer 2>&1 | tail -n 500 | grep -q "Flushed "; then
    echo "[itest] Kafka -> anonymizer OK (flush observed)"
    exit 0
  fi
  sleep 5
done

echo "[itest] FAILED: no flush observed in anonymizer logs"
exit 1

