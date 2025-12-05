# MariaDB Multi-Cluster Setup with ProxySQL

This setup creates a MariaDB cluster with:
- 2 Master nodes (master-to-master replication)
- 4 Slave nodes (2 slaves per master)
- ProxySQL for load balancing and query routing
- MariaDB 11.4 with aggressive performance tuning

## Configuration
Edit `.env` file to set passwords:
- MYSQL_ROOT_PASSWORD (default: password123)
- MYSQL_REPL_PASSWORD (default: replica123)
- MONITOR_PASSWORD (default: monitor123)

## Network
- Custom Docker network: `172.25.0.0/16`
- Gateway: `172.25.0.1`
- Internal communication only for replication and monitoring users

## Ports
- ProxySQL Client: 6033 (exposed publicly for connections)
- ProxySQL Admin: 6032 (admin interface)
- Master1: 3307
- Master2: 3308
- Slave1: 3309
- Slave2: 3310
- Slave3: 3311
- Slave4: 3312

## Quick Start
1. Start the cluster: `docker-compose up -d`
2. Wait for initialization (about 1-2 minutes)
3. Connect via ProxySQL: `mysql -h localhost -P 6033 -u root -p[MYSQL_ROOT_PASSWORD]`
4. Or use Navicat/DBeaver with host `localhost`, port `6033`

## Bench Script Usage

The `bench.ps1` (Windows) and `bench.sh` (Linux) scripts provide comprehensive cluster management.

### Basic Commands

**Start/Stop Cluster:**
```bash
# Windows
docker-compose up -d
docker-compose down

# Linux
docker-compose up -d
docker-compose down
```

### Performance Mode Switching

Switch between production (safe) and development (fast) modes **without destroying data or restarting containers**.

**Windows (PowerShell):**
```powershell
.\bench.ps1 mode development    # Set to FAST mode (5-10x faster writes)
.\bench.ps1 mode production     # Set to SAFE mode (durable)
.\bench.ps1 show-mode           # Show current mode settings
```

**Linux (Bash):**
```bash
./bench.sh mode development     # Set to FAST mode (5-10x faster writes)
./bench.sh mode production      # Set to SAFE mode (durable)
./bench.sh show-mode            # Show current mode settings
```

**Development Mode:**
- Speed: 5-10x faster for writes/imports
- Safety: ⚠️ Data can be lost on crash
- Use for: Development, testing, bulk data imports
- Settings: `innodb_flush_log_at_trx_commit=0`, `innodb_doublewrite=OFF`, `sync_binlog=0`

**Production Mode:**
- Speed: Normal (safe)
- Safety: ✓ Data protected against crashes
- Use for: Production, critical data
- Settings: `innodb_flush_log_at_trx_commit=2`, `innodb_doublewrite=ON`, `sync_binlog=1`

### Scaling Operations

**Add Nodes Dynamically:**

Windows:
```powershell
.\bench.ps1 add-master     # Add master3, master4, etc.
.\bench.ps1 add-slave      # Add slave5, slave6, etc.
.\bench.ps1 list-nodes     # List all nodes
.\bench.ps1 remove-node mariadb-slave5  # Remove specific node
```

Linux:
```bash
./bench.sh add-master      # Add master3, master4, etc.
./bench.sh add-slave       # Add slave5, slave6, etc.
./bench.sh list-nodes      # List all nodes
./bench.sh remove-node mariadb-slave5   # Remove specific node
```

### Benchmark Testing

**Run Performance Tests:**

Windows:
```powershell
.\bench.ps1 prepare        # Prepare database for benchmark
.\bench.ps1 run            # Run benchmark test
.\bench.ps1 cleanup        # Clean up test data
.\bench.ps1 all            # Run all (prepare, run, cleanup)
.\bench.ps1 stats          # Show database statistics
```

Linux:
```bash
./bench.sh prepare         # Prepare database for benchmark
./bench.sh run             # Run benchmark test
./bench.sh cleanup         # Clean up test data
./bench.sh all             # Run all (prepare, run, cleanup)
./bench.sh stats           # Show database statistics
```

### Maintenance Commands

**Reset Data:**

Windows:
```powershell
.\bench.ps1 reset              # Delete all data folders (requires confirmation)
.\bench.ps1 reset-and-start    # Reset data + auto restart cluster
```

Linux:
```bash
./bench.sh reset               # Delete all data folders (requires confirmation)
./bench.sh reset-and-start     # Reset data + auto restart cluster
```

### Common Workflows

**1. Fast Data Import:**
```bash
# Switch to development mode for maximum speed
./bench.sh mode development

# Import your large SQL file
mysql -h localhost -P 6033 -u root -p[password] < large_data.sql

# Switch back to production mode
./bench.sh mode production
```

**2. Scale Up for Load Testing:**
```bash
# Add more slaves for read capacity
./bench.sh add-slave    # Adds slave5
./bench.sh add-slave    # Adds slave6

# Check cluster status
./bench.sh list-nodes

# Run benchmark
./bench.sh all
```

**3. Reset and Start Fresh:**
```bash
# Quick reset without prompts
./bench.sh reset-and-start
```

## Architecture

### Replication Topology
- Master1 ↔ Master2 (bidirectional replication)
- Master1 → Slave1, Slave2
- Master2 → Slave3, Slave4

### ProxySQL Query Routing
- **SELECT queries** → Routed to slaves (hostgroup 20) for load distribution
- **INSERT/UPDATE/DELETE** → Routed to masters (hostgroup 10)
- **Connection pooling** → Multiplexing enabled, 4096 max connections
- **Query caching** → 256MB cache for frequently used queries

### Performance Optimizations
- InnoDB buffer pool: 3GB
- InnoDB log file: 1GB
- Max connections: 500 per node
- Read/Write IO threads: 16 each
- Connect timeout: 500ms
- Query cache: 256MB in ProxySQL

## User Privileges

- **root**: Can connect from anywhere, full privileges
- **repl**: Can only connect from internal network (172.25.%), replication privileges
- **monitor**: Can only connect from internal network (172.25.%), monitoring privileges

## Monitoring

**Check Replication Status:**
```bash
docker exec mariadb-master1 mariadb -uroot -p[password] -e "SHOW SLAVE STATUS\G"
docker exec mariadb-slave1 mariadb -uroot -p[password] -e "SHOW SLAVE STATUS\G"
```

**Check ProxySQL Stats:**
```bash
mysql -h127.0.0.1 -P6032 -uadmin -padmin -e "SELECT * FROM stats_mysql_connection_pool;"
mysql -h127.0.0.1 -P6032 -uadmin -padmin -e "SELECT * FROM stats_mysql_query_rules;"
```

**View Current Performance Mode:**
```bash
./bench.sh show-mode    # Linux
.\bench.ps1 show-mode   # Windows
```

## Troubleshooting

**Slow Connections?**
- ProxySQL optimized for fast connections (500ms timeout)
- If still slow, check network and increase `connect_timeout_server`

**Slow Writes?**
- Use `development` mode for faster writes (5-10x improvement)
- ⚠️ Remember to switch back to `production` mode when done

**Replication Lag?**
- Check with: `SHOW SLAVE STATUS\G`
- ProxySQL monitors lag automatically via `monitor` user
- Add more slaves if needed with `bench.sh add-slave`

**Connection Issues?**
- Verify passwords in `.env` file match
- Root can connect from anywhere
- Repl/monitor users only from 172.25.% network

## Notes
- Masters are writable, slaves are read-only
- Development mode sacrifices durability for speed - use with caution
- ProxySQL automatically removes slow/failed nodes from rotation
- All nodes run MariaDB 11.4 with Galera support
