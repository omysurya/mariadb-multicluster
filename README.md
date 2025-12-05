# MariaDB Multi-Cluster Setup with ProxySQL

This setup creates a MariaDB cluster with:
- 2 Master nodes (master-to-master replication)
- 4 Slave nodes (2 slaves per master)
- ProxySQL for load balancing and query routing
- MariaDB 11.4 with aggressive performance tuning

## Configuration

### Environment Variables (.env)
All credentials are configured in `.env` file for security and flexibility:
```env
MYSQL_ROOT_PASSWORD=password123
MYSQL_REPL_USER=repl
MYSQL_REPL_PASSWORD=replica123
MONITOR_USER=monitor
MONITOR_PASSWORD=monitor123
```

**Dynamic Configuration:**
- All scripts and configurations read from `.env` file
- No hardcoded passwords in docker-compose.yml or scripts
- Change `.env` and restart to update credentials
- Custom entrypoint wrapper substitutes variables into SQL templates

### User Initialization
Users are created automatically during container initialization using:
- **`scripts/init-users.sql`**: SQL template with variable placeholders
- **`scripts/entrypoint-wrapper.sh`**: Custom entrypoint that:
  - Performs `sed` substitution from template to executable SQL
  - Executes via MariaDB's built-in initialization mechanism
  - Ensures users created before replication starts

## Network & Security

### Network Isolation
- Custom Docker network: `172.25.0.0/16`
- Gateway: `172.25.0.1`
- Internal-only communication for database traffic
- Replication and monitoring users restricted to `172.25.%` hosts

### Port Security
**Publicly Accessible:**
- ProxySQL Client: `6033` → `0.0.0.0:6033` (public access for clients)

**Localhost Only:**
- ProxySQL Admin: `6032` → `127.0.0.1:6032` (admin interface, host-only)

**Container-Only (No Public Ports):**
- Master1, Master2: Port `3306` (internal container network only)
- Slave1, Slave2, Slave3, Slave4: Port `3306` (internal container network only)
- ⚠️ MariaDB nodes are NOT exposed to host - connect via ProxySQL port `6033` only

**Security Benefits:**
- Direct database access blocked from external networks
- All client connections must go through ProxySQL (monitoring, load balancing)
- Admin interface accessible only from host machine
- Database replication traffic stays within Docker network

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

### Initialization Scripts (Shared Approach)
All MariaDB nodes use shared initialization scripts from `scripts/` folder:

**`scripts/entrypoint-wrapper.sh`:**
- Custom entrypoint that intercepts container startup
- Performs environment variable substitution into SQL templates
- Generates `/docker-entrypoint-initdb.d/01-init-users.sql` dynamically
- Forwards execution to original MariaDB docker-entrypoint

**`scripts/init-users.sql`:**
- SQL template with placeholders: `${MYSQL_REPL_USER}`, `${MONITOR_USER}`, etc.
- Creates replication and monitoring users with credentials from `.env`
- Restricts access to internal network (`172.25.%`)
- Executed automatically on first container startup

**`scripts/setup-replication.sh`:**
- Configures master-slave replication automatically
- Uses `REPLICATION_MASTER` environment variable to identify master node
- Runs `CHANGE MASTER TO` with credentials from `.env`
- Executed on slave nodes and master2

### ProxySQL Query Routing
- **SELECT queries** → Routed to slaves (hostgroup 20) for load distribution
- **INSERT/UPDATE/DELETE** → Routed to masters (hostgroup 10)
- **Connection pooling** → Multiplexing enabled, 4096 max connections
- **Query caching** → 256MB cache for frequently used queries
- **Fast forward disabled** → Proper query parsing for root user
- **Connection timeout** → 3000ms server, 10000ms client

### Performance Optimizations
- InnoDB buffer pool: 3GB
- InnoDB log file: 1GB
- InnoDB log buffer: 256MB
- Max connections: 500 per node
- Read/Write IO threads: 16 each
- IO capacity: 4000/8000 (normal/max)
- Connect timeout: 3 seconds
- Table open cache: 8000
- Skip name resolve and host cache for faster connections

## User Privileges & Access Control

### Root User
- **Username**: `root`
- **Password**: Configured in `.env` as `MYSQL_ROOT_PASSWORD`
- **Access**: Can connect from anywhere (`%`)
- **Privileges**: ALL PRIVILEGES WITH GRANT OPTION
- **Use case**: Database administration, schema changes

### Replication User
- **Username**: Configured in `.env` as `MYSQL_REPL_USER` (default: `repl`)
- **Password**: Configured in `.env` as `MYSQL_REPL_PASSWORD`
- **Access**: Internal network only (`172.25.%`)
- **Privileges**: REPLICATION SLAVE, REPLICATION CLIENT, SLAVE MONITOR, PROCESS
- **Use case**: Master-to-master and master-to-slave replication
- **Security**: Cannot connect from outside Docker network

### Monitor User
- **Username**: Configured in `.env` as `MONITOR_USER` (default: `monitor`)
- **Password**: Configured in `.env` as `MONITOR_PASSWORD`
- **Access**: Internal network only (`172.25.%`)
- **Privileges**: SELECT, REPLICATION CLIENT, SLAVE MONITOR, PROCESS
- **Use case**: ProxySQL health checks and monitoring
- **Security**: Cannot connect from outside Docker network

**Note:** All users are created automatically via shared initialization scripts during first container startup.

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
- ProxySQL optimized for fast connections (3000ms timeout)
- Check network latency: `docker exec proxysql ping mariadb-master1`
- Verify fast_forward settings in ProxySQL config

**Slow Writes?**
- Use `development` mode for faster writes (5-10x improvement)
- ⚠️ Remember to switch back to `production` mode when done
- Development mode: `innodb_flush_log_at_trx_commit=0`, `sync_binlog=0`

**Replication Lag?**
- Check with: `SHOW SLAVE STATUS\G`
- ProxySQL monitors lag automatically via `monitor` user
- Max replication lag: 30 seconds for slaves (configurable)
- Add more slaves if needed with `bench.sh add-slave`

**Connection Issues?**
- ⚠️ **Cannot connect to MariaDB directly** - MariaDB ports not exposed to host
- ✅ **Connect via ProxySQL** on port `6033` instead
- Verify passwords in `.env` file match
- Root can connect from anywhere (via ProxySQL)
- Repl/monitor users only from 172.25.% network (internal)

**User Creation Errors?**
- Users are created via `scripts/entrypoint-wrapper.sh` + `scripts/init-users.sql`
- Check logs: `docker-compose logs mariadb-master1 | grep -i "user\|error"`
- Verify `.env` file exists and contains all 5 variables
- If users not created, check entrypoint wrapper has execute permission
- Reset data and restart: `./bench.sh reset-and-start`

**ProxySQL Can't Connect to MariaDB?**
- Error: "Access denied for user 'monitor'@'172.25.0.x'"
- Solution: Users not created properly - check initialization scripts
- Verify: `docker exec mariadb-master1 mariadb -uroot -p[password] -e "SELECT User, Host FROM mysql.user;"`
- Should see `monitor` and `repl` users with Host='172.25.%'

**docker-compose command not found (Linux)?**
- Script auto-detects Docker Compose v1 (`docker-compose`) or v2 (`docker compose`)
- Install Docker Compose: `sudo apt install docker-compose` or use Docker Desktop

## Security Best Practices

1. **Change Default Passwords**: Edit `.env` file with strong passwords before first deployment
2. **Network Isolation**: Database nodes only accessible within Docker network
3. **ProxySQL Gateway**: All external connections must go through ProxySQL (port 6033)
4. **Admin Access**: ProxySQL admin interface (6032) bound to localhost only
5. **User Restrictions**: Replication and monitoring users can only connect from internal network
6. **No Direct Access**: MariaDB ports (3306) not exposed to host - prevents unauthorized access

## Version Information

- **MariaDB**: 11.4 (latest stable)
- **ProxySQL**: Latest version with query caching and connection pooling
- **Docker Compose**: Compatible with v1 and v2 (auto-detected by bench scripts)
- **OS Support**: Windows (PowerShell) and Linux (Bash) management scripts

## Notes

- Masters are writable, slaves are read-only (`--read-only=ON`)
- Development mode sacrifices durability for speed - use with caution
- ProxySQL automatically removes slow/failed nodes from rotation
- All nodes run MariaDB 11.4 with optimized InnoDB settings
- User creation handled by custom entrypoint wrapper with environment variable substitution
- Shared initialization scripts ensure consistent configuration across all nodes
- Binary logging disabled during user creation to prevent replication conflicts
