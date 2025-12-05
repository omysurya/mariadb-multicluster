-- SQL template for user initialization
-- Environment variables will be substituted by entrypoint-wrapper.sh

-- Disable binary logging untuk user management (prevent replication conflicts)
SET sql_log_bin=0;

-- User untuk replikasi - hanya akses dari network internal (172.25.0.0/16)
DROP USER IF EXISTS '${MYSQL_REPL_USER}'@'172.25.%';
CREATE USER '${MYSQL_REPL_USER}'@'172.25.%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, SLAVE MONITOR, PROCESS ON *.* TO '${MYSQL_REPL_USER}'@'172.25.%';

-- User untuk monitoring - hanya akses dari network internal (172.25.0.0/16)
DROP USER IF EXISTS '${MONITOR_USER}'@'172.25.%';
CREATE USER '${MONITOR_USER}'@'172.25.%' IDENTIFIED BY '${MONITOR_PASSWORD}';
GRANT SELECT, REPLICATION CLIENT, SLAVE MONITOR, PROCESS ON *.* TO '${MONITOR_USER}'@'172.25.%';

-- Root user sudah dibuat oleh Docker dengan akses dari manapun (%)
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;

-- Re-enable binary logging
SET sql_log_bin=1;
