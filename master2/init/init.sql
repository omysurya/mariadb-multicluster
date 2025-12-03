CREATE USER 'repl'@'%' IDENTIFIED BY 'replpassword';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
CREATE USER 'monitor'@'%' IDENTIFIED BY 'monitor';
GRANT SELECT ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;

-- Wait for master1 to be ready
SELECT SLEEP(10);

-- Setup replication from master1
CHANGE MASTER TO MASTER_HOST='mariadb-master1', MASTER_USER='repl', MASTER_PASSWORD='replpassword', MASTER_PORT=3306, MASTER_USE_GTID=slave_pos;
START SLAVE;