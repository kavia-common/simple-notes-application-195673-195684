#!/bin/bash
set -euo pipefail

# MongoDB startup script
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"

# Use container-provided PORT when available; default expected by platform is 5001
DB_PORT="${PORT:-5001}"

echo "Starting MongoDB setup..."
echo "Target port: ${DB_PORT}"

# Ensure required directories exist (common container images may not pre-create these)
sudo mkdir -p /var/lib/mongodb /var/run/mongodb
# Avoid permission issues if running as root in container; keep consistent ownership.
sudo chown -R "$(id -u):$(id -g)" /var/lib/mongodb /var/run/mongodb || true

# If mongod is already listening on the expected port, keep it and proceed.
if mongosh --quiet --port "${DB_PORT}" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
  echo "MongoDB is already running on port ${DB_PORT}."
else
  # If another mongod is running (possibly on a different port), stop it to avoid conflicts.
  if pgrep -x mongod >/dev/null; then
    echo "A mongod process is already running; stopping it to ensure correct port binding..."
    sudo pkill -x mongod || true
    sleep 2
  fi

  # Clean up any existing socket files that can block startup.
  sudo rm -f /tmp/mongodb-*.sock 2>/dev/null || true
  sudo rm -f /var/run/mongodb/mongodb-*.sock 2>/dev/null || true

  echo "Starting mongod..."
  # Start in background temporarily so we can provision users; we'll restart in foreground at the end.
  sudo mongod \
    --dbpath /var/lib/mongodb \
    --port "${DB_PORT}" \
    --bind_ip_all \
    --unixSocketPrefix /var/run/mongodb \
    --logpath /var/lib/mongodb/mongod.log \
    --fork

  echo "Waiting for MongoDB to become ready..."
  for i in {1..30}; do
    if mongosh --quiet --port "${DB_PORT}" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
      echo "MongoDB is ready."
      break
    fi
    echo "Waiting... (${i}/30)"
    sleep 1
  done

  if ! mongosh --quiet --port "${DB_PORT}" --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
    echo "ERROR: MongoDB did not become ready on port ${DB_PORT}."
    echo "Last 200 lines of mongod log:"
    sudo tail -n 200 /var/lib/mongodb/mongod.log || true
    exit 1
  fi
fi

echo "Setting up database and users..."
mongosh --quiet --port "${DB_PORT}" << EOF
use admin

if (db.getUser("${DB_USER}") == null) {
  db.createUser({
    user: "${DB_USER}",
    pwd: "${DB_PASSWORD}",
    roles: [
      { role: "userAdminAnyDatabase", db: "admin" },
      { role: "readWriteAnyDatabase", db: "admin" }
    ]
  });
}

use ${DB_NAME}

if (db.getUser("appuser") == null) {
  db.createUser({
    user: "appuser",
    pwd: "${DB_PASSWORD}",
    roles: [
      { role: "readWrite", db: "${DB_NAME}" }
    ]
  });
}

print("MongoDB setup complete!");
EOF

# Save connection command to a file (platform instruction: prefer reading from db_connection.txt)
echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables for db_visualizer
cat > db_visualizer/mongodb.env << EOF
export MONGODB_URL="mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/?authSource=admin"
export MONGODB_DB="${DB_NAME}"
EOF

echo "MongoDB configured. Ensuring mongod runs in foreground for container lifecycle..."

# If we started mongod earlier with --fork, stop it and restart in foreground so PID1 stays alive.
if pgrep -x mongod >/dev/null; then
  sudo pkill -x mongod || true
  sleep 2
fi

# Run mongod as the main container process (foreground). This improves healthcheck stability.
exec sudo mongod \
  --dbpath /var/lib/mongodb \
  --port "${DB_PORT}" \
  --bind_ip_all \
  --unixSocketPrefix /var/run/mongodb \
  --logpath /var/lib/mongodb/mongod.log
