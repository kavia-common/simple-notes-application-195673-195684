#!/bin/bash

# MongoDB startup script following the same pattern
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting MongoDB setup..."

# Check if MongoDB is already running
if mongosh --port ${DB_PORT} --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
    echo "MongoDB is already running on port ${DB_PORT}!"
    
    # Try to verify the database exists and user can connect
    if mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin --eval "db.getName()" > /dev/null 2>&1; then
        echo "Database ${DB_NAME} is accessible with user ${DB_USER}."
    else
        echo "MongoDB is running but authentication might not be configured."
    fi
    
    echo ""
    echo "Database: ${DB_NAME}"
    echo "Admin user: ${DB_USER} (password: ${DB_PASSWORD})"
    echo "App user: appuser (password: ${DB_PASSWORD})"
    echo "Port: ${DB_PORT}"
    echo ""
    
    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "To connect to the database, use:"
        echo "$(cat db_connection.txt)"
    else
        echo "To connect to the database, use:"
        echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin"
    fi
    
    echo ""
    echo "Script stopped - MongoDB server already running."
    exit 0
fi

# Check if MongoDB is running on a different port
if pgrep -x mongod > /dev/null; then
    # Get the port of the running MongoDB instance
    MONGO_PID=$(pgrep -x mongod)
    CURRENT_PORT=$(sudo lsof -Pan -p $MONGO_PID -i | grep -o ":[0-9]*" | grep -o "[0-9]*" | head -1)
    
    if [ "$CURRENT_PORT" = "${DB_PORT}" ]; then
        echo "MongoDB is already running on port ${DB_PORT}!"
        echo "Script stopped - server already running."
        exit 0
    else
        echo "MongoDB is running on different port ($CURRENT_PORT), stopping it..."
        sudo pkill -x mongod
        sleep 2
    fi
fi

# Clean up any existing socket files
sudo rm -f /tmp/mongodb-*.sock 2>/dev/null

# Start MongoDB server without authentication initially using nohup
echo "Starting MongoDB server..."
nohup sudo mongod --dbpath /var/lib/mongodb --port ${DB_PORT} --bind_ip 127.0.0.1 --unixSocketPrefix /var/run/mongodb > /var/lib/mongodb/mongod.log 2>&1 &

# Wait for MongoDB to start
echo "Waiting for MongoDB to start..."
sleep 5

# Check if MongoDB is running
for i in {1..15}; do
    if mongosh --port ${DB_PORT} --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
        echo "MongoDB is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
mongosh --port ${DB_PORT} << EOF
// Switch to admin database for user creation
use admin

// Create admin user if it doesn't exist
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

// Switch to target database
use ${DB_NAME}

// Create application user for specific database
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

# Save connection command to a file
echo "mongosh mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}?authSource=admin" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/mongodb.env << EOF
export MONGODB_URL="mongodb://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/?authSource=admin"
export MONGODB_DB="${DB_NAME}"
EOF

echo "MongoDB setup complete!"
echo "Database: ${DB_NAME}"
echo "Admin user: ${DB_USER} (password: ${DB_PASSWORD})"
echo "App user: appuser (password: ${DB_PASSWORD})"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/mongodb.env"
echo "To use with Node.js viewer, run: source db_visualizer/mongodb.env"

echo "To connect to the database, use one of the following commands:"
echo "mongosh -u ${DB_USER} -p ${DB_PASSWORD} --port ${DB_PORT} --authenticationDatabase admin ${DB_NAME}"
echo "$(cat db_connection.txt)"

# MongoDB continues running in background
echo ""
echo "MongoDB is running in the background."
echo "You can now start your application."