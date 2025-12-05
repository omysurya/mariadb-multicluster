#!/bin/bash
# Script untuk setup replication ke master

# Wait for MariaDB to be ready
until mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" &> /dev/null; do
    echo "Waiting for MariaDB to be ready..."
    sleep 2
done

echo "MariaDB is ready, setting up replication to ${REPLICATION_MASTER}..."

# Setup replication if REPLICATION_MASTER is set
if [ -n "${REPLICATION_MASTER}" ]; then
    mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CHANGE MASTER TO
    MASTER_HOST='${REPLICATION_MASTER}',
    MASTER_USER='${MYSQL_REPL_USER:-repl}',
    MASTER_PASSWORD='${MYSQL_REPL_PASSWORD}',
    MASTER_PORT=3306,
    MASTER_CONNECT_RETRY=10;

START SLAVE;
EOF
    echo "✓ Replication configured to ${REPLICATION_MASTER} using user ${MYSQL_REPL_USER:-repl}"
else
    echo "ℹ No REPLICATION_MASTER set, skipping replication setup"
fi
