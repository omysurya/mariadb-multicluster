#!/bin/bash
# Entrypoint wrapper untuk inject environment variables ke SQL template

set -e

# Generate init SQL file dengan environment variable substitution using sed
sed -e "s/\${MYSQL_REPL_USER}/${MYSQL_REPL_USER}/g" \
    -e "s/\${MYSQL_REPL_PASSWORD}/${MYSQL_REPL_PASSWORD}/g" \
    -e "s/\${MONITOR_USER}/${MONITOR_USER}/g" \
    -e "s/\${MONITOR_PASSWORD}/${MONITOR_PASSWORD}/g" \
    /tmp/init-template.sql > /docker-entrypoint-initdb.d/01-init-users.sql

# Run original docker-entrypoint dengan pass semua arguments (termasuk command dari docker-compose)
exec /usr/local/bin/docker-entrypoint.sh mariadbd "$@"
