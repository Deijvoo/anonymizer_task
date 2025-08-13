#!/usr/bin/env bash
set -euo pipefail

echo "[e2e] ensuring docker compose is up..."
docker compose ps >/dev/null

echo "[e2e] waiting for core services (clickhouse, ch-proxy, grafana, prometheus, broker)..."
deadline=$(( $(date +%s) + 120 ))
until curl -fsS "http://localhost:8123/?query=SELECT%201" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "[e2e] clickhouse http not ready"; exit 1; };
  sleep 2
done
until curl -fsS "http://localhost:8124/?query=SELECT%201" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "[e2e] ch-proxy not ready"; exit 1; };
  sleep 2
done
until curl -fsS "http://localhost:3001/login" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "[e2e] grafana not ready"; exit 1; };
  sleep 2
done
until curl -fsS "http://localhost:9090/-/ready" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "[e2e] prometheus not ready"; exit 1; };
  sleep 2
done

echo "[e2e] verifying kafka topic exists (http_log)..."
if ! docker compose exec -T broker kafka-topics --bootstrap-server broker:29092 --describe --topic http_log >/dev/null 2>&1; then
  echo "[e2e] topic http_log not found; creating..."
  docker compose exec -T broker kafka-topics --bootstrap-server broker:29092 --create --if-not-exists --topic http_log --partitions 1 --replication-factor 1 >/dev/null
fi

echo "[e2e] verifying ClickHouse schema..."
exists=$(curl -fsS "http://localhost:8123/?query=EXISTS%20logs.http_log") || exists=0
if [ "$exists" != "1" ]; then
  echo "[e2e] logs.http_log missing"; exit 1
fi

echo "[e2e] baseline row count..."
initial=$(curl -fsS "http://localhost:8123/?query=SELECT%20count()%20FROM%20logs.http_log") || initial=0
echo "initial=$initial"
mark_ts=$(date +%s)

echo "[e2e] start temporary fast producer..."
docker compose run -d --name e2e-producer -e KAFKA_BOOTSTRAP_SERVERS=broker:29092 -e KAFKA_PRODUCER_DELAY_MS=100 http-log-kafka-producer >/dev/null
sleep 10
docker stop e2e-producer >/dev/null 2>&1 || true
docker rm e2e-producer >/dev/null 2>&1 || true

echo "[e2e] waiting for row count increase (up to 150s, polling 5s)..."
deadline2=$(( $(date +%s) + 150 ))
inc=0
while (( $(date +%s) < deadline2 )); do
  after=$(curl -fsS "http://localhost:8123/?query=SELECT%20count()%20FROM%20logs.http_log") || after=0
  echo "after=$after"
  if [ "$after" -gt "$initial" ]; then inc=1; break; fi
  sleep 5
done
if [ "$inc" -ne 1 ]; then
  echo "[e2e] FAIL: row count did not increase";
  echo "[e2e] recent anonymizer logs:";
  docker logs --since 5m anonymizer | tail -n 200;
  exit 1
fi

echo "[e2e] FULL E2E OK"

# Extra checks
echo "[e2e] verifying Prometheus Kafka scrape via API..."
bash tests/integration/prometheus_kafka_metrics.sh

echo "[e2e] simulating Kafka broker failure and recovery..."
bash tests/integration/kafka_failure.sh

echo "[e2e] printing ClickHouse E2E latency quantiles (last 1h)..."
bash tests/integration/clickhouse_latency_quantiles.sh | sed 's/^/[e2e-latency] /'

echo "[e2e] ALL CHECKS OK"

