# MariaDB Multi-Cluster Setup with ProxySQL

This setup creates a MariaDB cluster with:
- 2 Master nodes (master-to-master replication)
- 4 Slave nodes (2 slaves per master)
- ProxySQL for load balancing (70% read, 30% write)

## Configuration
Edit `.env` file to set passwords:
- MYSQL_ROOT_PASSWORD
- MYSQL_REPL_PASSWORD
- MONITOR_PASSWORD

## Ports
- ProxySQL: 6033 (exposed publicly)
- Master1: 3307
- Master2: 3308
- Slave1: 3309
- Slave2: 3310
- Slave3: 3311
- Slave4: 3312

## Usage
1. Start the cluster: `docker-compose up -d`
2. Wait for initialization (about 1-2 minutes)
3. Connect to ProxySQL: `mysql -h localhost -P 6033 -u root -p${MYSQL_ROOT_PASSWORD}`
4. Root user can login from any host/IP.

## Notes
- Masters are writable, slaves are read-only.
- ProxySQL routes SELECT to slaves (HG 20), others to masters (HG 10).
- Optimized for high traffic with increased connections and threads.# mariadb-multicluster
