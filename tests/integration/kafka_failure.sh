#!/usr/bin/env bash
set -euo pipefail

# Simulate Kafka broker failure and verify anonymizer recovers and rows continue to flow.

echo "[itest-kafka-fail] ensuring compose is reachable..."
docker compose ps >/dev/null

CH=http://localhost:8123

echo "[itest-kafka-fail] verifying ClickHouse reachable..."
deadline=$(( $(date +%s) + 60 ))
until curl -fsS "$CH/?query=SELECT%201" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "[itest-kafka-fail] ClickHouse not ready"; exit 1; };
  sleep 2
done

echo "[itest-kafka-fail] baseline row count..."
initial=$(curl -fsS "$CH/?query=SELECT%20count()%20FROM%20logs.http_log" || echo 0)
echo "initial=$initial"

echo "[itest-kafka-fail] stopping Kafka broker for 10s..."
docker compose stop broker >/dev/null
sleep 10

echo "[itest-kafka-fail] starting Kafka broker..."
docker compose start broker >/dev/null

echo "[itest-kafka-fail] kick a short burst producer..."
docker compose run -d --name itest-fail-producer -e KAFKA_BOOTSTRAP_SERVERS=broker:29092 -e KAFKA_PRODUCER_DELAY_MS=100 http-log-kafka-producer >/dev/null || true
sleep 10
docker stop itest-fail-producer >/dev/null 2>&1 || true
docker rm itest-fail-producer >/dev/null 2>&1 || true

echo "[itest-kafka-fail] waiting for row count to increase (up to 180s)..."
deadline2=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline2 )); do
  after=$(curl -fsS "$CH/?query=SELECT%20count()%20FROM%20logs.http_log" || echo 0)
  echo "after=$after"
  if [ "$after" -gt "$initial" ]; then
    echo "[itest-kafka-fail] OK: rows increased after broker recovery"
    exit 0
  fi
  sleep 5
done

echo "[itest-kafka-fail] FAILED: row count did not increase after broker restart"
echo "[itest-kafka-fail] recent anonymizer logs:"
docker logs --since 5m anonymizer | tail -n 200 || true
exit 1

