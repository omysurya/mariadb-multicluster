-- Root user sudah dibuat oleh Docker dengan akses dari manapun (%) via MYSQL_ROOT_PASSWORD
-- User 'repl' sudah dibuat oleh Docker via MYSQL_USER/MYSQL_PASSWORD

-- SKIP BINLOG untuk menghindari replikasi user management yang bisa konflik
SET sql_log_bin=0;

-- Drop dan recreate user repl dengan host pattern yang benar
DROP USER IF EXISTS 'repl'@'%';
DROP USER IF EXISTS 'repl'@'localhost';
CREATE USER 'repl'@'172.25.%' IDENTIFIED BY 'replica123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'172.25.%';

-- Create monitor user untuk ProxySQL - hanya akses dari internal network
CREATE USER IF NOT EXISTS 'monitor'@'172.25.%' IDENTIFIED BY 'monitor123';
GRANT SELECT, REPLICATION CLIENT, REPLICATION SLAVE, PROCESS ON *.* TO 'monitor'@'172.25.%';
GRANT SLAVE MONITOR ON *.* TO 'monitor'@'172.25.%';

FLUSH PRIVILEGES;

-- Enable binlog kembali
SET sql_log_bin=1;

-- Wait for master2 to be ready
SELECT SLEEP(30);

-- Setup replication from master2
CHANGE MASTER TO MASTER_HOST='mariadb-master2', MASTER_USER='repl', MASTER_PASSWORD='replica123', MASTER_PORT=3306;
START SLAVE;
