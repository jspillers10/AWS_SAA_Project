#!/bin/bash
# Retry for up to ~30s instead of a blind sleep
for i in $(seq 1 10); do
  if curl -fsS http://localhost/health.php >/dev/null; then
    echo "Service validation passed"
    exit 0
  fi
  sleep 3
done
echo "Service validation failed"
exit 1
