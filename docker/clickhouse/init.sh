#!/bin/sh
set -e

HOST="clickhouse-server"

echo "[clickhouse-init] Waiting for ClickHouse at $HOST..."
for i in $(seq 1 60); do
  if clickhouse-client --host "$HOST" -q "SELECT 1" >/dev/null 2>&1; then
    echo "[clickhouse-init] ClickHouse is up"
    break
  fi
  sleep 2
done

echo "[clickhouse-init] Applying schema /init/01_schema.sql"
clickhouse-client --host "$HOST" -n < /init/01_schema.sql
echo "[clickhouse-init] Schema applied"

