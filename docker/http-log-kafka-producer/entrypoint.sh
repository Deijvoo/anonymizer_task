#!/bin/sh
# busybox sh nemá -o pipefail; nepoužívaj 'set -eu' kvôli kompatibilite

# Sanitize env (remove quotes/CRLF that can sneak in on Windows)
BOOTSTRAP=$(printf '%s' "${KAFKA_BOOTSTRAP_SERVERS:-broker:29092}" | tr -d '"\r')
DELAY=$(printf '%s' "${KAFKA_PRODUCER_DELAY_MS:-5000}" | tr -d '"\r')

exec java -jar /home/httploggen-1.0.0-jar-with-dependencies.jar --bootstrap "$BOOTSTRAP" --delay "$DELAY"
