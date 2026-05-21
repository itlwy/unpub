#!/bin/bash
cd /src/unpub
export UNPUB_PACKAGE_DIR=/data/db/unpub-packages

# Start mongod and record PID
mongod >mongo_out.file 2>&1 &
echo $! > /tmp/mongod.pid

# Wait for MongoDB to accept connections
echo "Waiting for MongoDB to be ready..."
until mongosh --quiet --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
  sleep 1
done
echo "MongoDB is ready (PID $(cat /tmp/mongod.pid))"

# Watchdog: restart mongod if it crashes
(
  while true; do
    sleep 5
    PID=$(cat /tmp/mongod.pid 2>/dev/null)
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
      echo "$(date): mongod died, restarting..."
      mongod >mongo_out.file 2>&1 &
      echo $! > /tmp/mongod.pid
      echo "$(date): mongod restarted (PID $(cat /tmp/mongod.pid))"
    fi
  done
) &

dart pub get
exec dart bin/unpub.dart
