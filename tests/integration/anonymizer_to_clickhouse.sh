#!/usr/bin/env bash
set -euo pipefail

# Verifies anonymizer -> ClickHouse: row count increases after a flush window.

CH=http://localhost:8123

echo "[itest] reading initial row count..."
initial=$(curl -s "$CH/?query=SELECT%20count()%20FROM%20logs.http_log" || echo 0)
echo "initial=$initial"

echo "[itest] waiting 75s for next flush window..."
sleep 75

after=$(curl -s "$CH/?query=SELECT%20count()%20FROM%20logs.http_log" || echo 0)
echo "after=$after"

if [ "$after" -gt "$initial" ]; then
  echo "[itest] anonymizer -> ClickHouse OK"
  exit 0
fi

echo "[itest] FAILED: row count did not increase"
exit 1

