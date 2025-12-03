CREATE USER 'monitor'@'%' IDENTIFIED BY 'monitor';
GRANT SELECT ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;

-- Wait for master2 to be ready
SELECT SLEEP(15);

-- Setup replication from master2
CHANGE MASTER TO MASTER_HOST='mariadb-master2', MASTER_USER='repl', MASTER_PASSWORD='replpassword', MASTER_PORT=3306;
START SLAVE;