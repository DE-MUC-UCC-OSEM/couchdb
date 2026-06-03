#!/bin/bash

set -euo pipefail

# Wait for Nouveau to accept TCP connections before starting CouchDB.
NOUVEAU_TIMEOUT="${NOUVEAU_TIMEOUT:-60}"
for ((i = 0; i < NOUVEAU_TIMEOUT; i++)); do
  if (echo > /dev/tcp/localhost/5987) 2>/dev/null; then
    break
  fi
  echo "Waiting for Nouveau..."
  sleep 1
done

if ! (echo > /dev/tcp/localhost/5987) 2>/dev/null; then
  echo "ERROR: Nouveau did not become ready within ${NOUVEAU_TIMEOUT}s" >&2
  exit 1
fi

exec /opt/couchdb/bin/couchdb
