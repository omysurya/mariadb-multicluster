#!/bin/bash

if [ -f "$(dirname "$0")/.env" ]; then
    set -a # automatically export all variables
    source "$(dirname "$0")/.env"
    set +a
fi

# Nama file: bench
# SysBench Benchmark + System Metrics (compatible with SysBench 1.0.20)

########################################
# Konfigurasi Database
########################################
DB_HOST="127.0.0.1"
DB_PORT="6033"
DB_USER="root"
DB_PASS="${MYSQL_ROOT_PASSWORD:-rootpassword}"
DB_NAME="sbtest"

########################################
# Konfigurasi SysBench
########################################
TABLES=100
TABLE_SIZE=100000000
THREADS=32
RUNTIME=60
REPORT_INTERVAL=5

SYSBENCH_SCRIPT="/usr/share/sysbench/oltp_read_write.lua"

########################################
# Warna Output
########################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m"

########################################
# Direktori Log
########################################
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

SYSBENCH_LOG="$LOG_DIR/sysbench.log"
CPU_LOG="$LOG_DIR/cpu.log"
RAM_LOG="$LOG_DIR/ram.log"
IO_LOG="$LOG_DIR/io.log"
NET_LOG="$LOG_DIR/net.log"

########################################
# Cek dependensi
########################################
check_dependencies() {
    echo -e "${BLUE}➤ Mengecek dependensi...${NC}"

    for bin in sysbench mariadb vmstat iostat sar; do
        if ! command -v $bin &>/dev/null; then
            echo -e "${RED}✖ Error: '$bin' tidak ditemukan.${NC}"
            exit 1
        fi
    done

    if [ ! -f "$SYSBENCH_SCRIPT" ]; then
        echo -e "${RED}✖ Script SysBench tidak ditemukan: $SYSBENCH_SCRIPT${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Semua dependensi OK.${NC}"
}

########################################
# Monitoring CPU, RAM, IO, Network
########################################
start_monitoring() {
    echo -e "${BLUE}➤ Memulai monitoring sistem...${NC}"

    echo "CPU Monitoring" > "$CPU_LOG"
    sar -u 1 >> "$CPU_LOG" & CPU_PID=$!

    echo "RAM Monitoring" > "$RAM_LOG"
    vmstat 1 >> "$RAM_LOG" & RAM_PID=$!

    echo "IO Monitoring" > "$IO_LOG"
    iostat -dx 1 >> "$IO_LOG" & IO_PID=$!

    echo "Network Monitoring" > "$NET_LOG"
    sar -n DEV 1 | grep -E "eth0|ens|enp" >> "$NET_LOG" & NET_PID=$!

    echo -e "${GREEN}✓ Monitoring dimulai.${NC}"
}

stop_monitoring() {
    echo -e "${YELLOW}➤ Menghentikan monitoring...${NC}"
    kill $CPU_PID 2>/dev/null
    kill $RAM_PID 2>/dev/null
    kill $IO_PID 2>/dev/null
    kill $NET_PID 2>/dev/null
    echo -e "${GREEN}✓ Monitoring dihentikan.${NC}"
}

########################################
# Cleanup Data
########################################
cleanup() {
    echo -e "${YELLOW}⚙️  Cleanup...${NC}"

    sysbench "$SYSBENCH_SCRIPT" \
        --db-driver=mysql \
        --mysql-host="$DB_HOST" \
        --mysql-port="$DB_PORT" \
        --mysql-user="$DB_USER" \
        --mysql-password="$DB_PASS" \
        --mysql-db="$DB_NAME" \
        --tables="$TABLES" \
        --table-size="$TABLE_SIZE" \
        cleanup

    echo -e "${GREEN}✓ Cleanup selesai.${NC}"
}

########################################
# Prepare Database
########################################
prepare() {
    echo -e "${BLUE}🛠 Menyiapkan database '$DB_NAME'...${NC}"

    mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" \
        -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"

    sysbench "$SYSBENCH_SCRIPT" \
        --db-driver=mysql \
        --mysql-host="$DB_HOST" \
        --mysql-port="$DB_PORT" \
        --mysql-user="$DB_USER" \
        --mysql-password="$DB_PASS" \
        --mysql-db="$DB_NAME" \
        --tables="$TABLES" \
        --table-size="$TABLE_SIZE" \
        prepare

    echo -e "${GREEN}✓ Persiapan selesai.${NC}"
}

########################################
# Tampilkan Statistik Database
########################################
show_db_stats() {
    echo -e "${BLUE}➤ Menampilkan Statistik Database & InnoDB...${NC}"

    STATS=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "
        SELECT 'INNODB_BUFFER_POOL_SIZE' AS variable, @@innodb_buffer_pool_size AS value UNION ALL
        SELECT 'INNODB_LOG_FILE_SIZE', @@innodb_log_file_size UNION ALL
        SELECT 'INNODB_FLUSH_LOG_AT_TRX_COMMIT', @@innodb_flush_log_at_trx_commit UNION ALL
        SELECT 'INNODB_FLUSH_METHOD', @@innodb_flush_method UNION ALL
        SELECT 'MAX_CONNECTIONS', @@max_connections;
        SHOW GLOBAL STATUS LIKE 'Max_used_connections';
    ")

    echo -e "${YELLOW}----------------------------------------${NC}"
    echo "$STATS"
    echo -e "${YELLOW}----------------------------------------${NC}"
}

########################################
# Jalankan Benchmark Test
########################################
run_test() {
    echo -e "${BLUE}🔥 Menjalankan Stress Test OLTP...${NC}"

    # Cek jika tabel ada
    TABLE_EXIST=$(mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${DB_NAME}' AND table_name = 'sbtest1';")
    if [ $(echo "$TABLE_EXIST" | tail -n1) -eq 0 ]; then
        echo -e "${RED}✖ Tabel 'sbtest1' tidak ditemukan di database '${DB_NAME}'.${NC}"
        echo -e "${YELLOW}➤ Silakan jalankan '$0 prepare' terlebih dahulu.${NC}"
        exit 1
    fi

    show_db_stats

    echo "   Threads: $THREADS (Users/Connections)"
    echo "   Durasi : $RUNTIME detik"

    start_monitoring

    sysbench "$SYSBENCH_SCRIPT" \
        --db-driver=mysql \
        --mysql-host="$DB_HOST" \
        --mysql-port="$DB_PORT" \
        --mysql-user="$DB_USER" \
        --mysql-password="$DB_PASS" \
        --mysql-db="$DB_NAME" \
        --tables="$TABLES" \
        --table-size="$TABLE_SIZE" \
        --threads="$THREADS" \
        --time="$RUNTIME" \
        --report-interval="$REPORT_INTERVAL" \
        run | tee "$SYSBENCH_LOG"

    stop_monitoring

    echo -e "${GREEN}✓ Benchmark selesai.${NC}"

    echo -e "${BLUE}➤ Menampilkan Ringkasan Statistik Sistem:${NC}"
    echo -e "${YELLOW}--- CPU Usage ---${NC}"
    tail -n 5 "$CPU_LOG"
    echo -e "${YELLOW}--- RAM Usage ---${NC}"
    tail -n 5 "$RAM_LOG"
    echo -e "${YELLOW}--- IO Usage ---${NC}"
    tail -n 5 "$IO_LOG"
    echo -e "${YELLOW}--- Network Usage ---${NC}"
    tail -n 5 "$NET_LOG"
}

########################################
# Trap CTRL+C
########################################
trap_ctrl_c() {
    echo -e "${RED}\nCTRL+C ditekan!${NC}"
    stop_monitoring
    exit 1
}
trap trap_ctrl_c INT

########################################
# Dynamic Scaling Functions
########################################

# Fungsi untuk mendapatkan nomor terakhir dari container
get_last_number() {
    local type=$1  # "master" atau "slave"
    local last_num=$(docker ps -a --format '{{.Names}}' | grep "mariadb-${type}" | sed "s/mariadb-${type}//" | sort -n | tail -1)
    echo "${last_num:-0}"
}

# Fungsi untuk mendapatkan server_id terakhir
get_last_server_id() {
    local max_id=0
    for container in $(docker ps --format '{{.Names}}' | grep "mariadb-"); do
        local server_id=$(docker exec $container mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT @@server_id;" 2>/dev/null | tail -1)
        if [ "$server_id" -gt "$max_id" ]; then
            max_id=$server_id
        fi
    done
    echo $max_id
}

# Fungsi untuk membuat init.sql untuk node baru
create_init_sql() {
    local node_name=$1
    local master_host=$2
    local init_file="${node_name}/init/init.sql"

    mkdir -p "${node_name}/init"
    mkdir -p "${node_name}/data"

    cat > "$init_file" <<'EOF'
-- User untuk replikasi - hanya akses dari network internal (172.25.0.0/16)
CREATE USER IF NOT EXISTS 'repl'@'172.25.%' IDENTIFIED BY 'replica123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'172.25.%';

-- User untuk monitoring - hanya akses dari network internal (172.25.0.0/16)
CREATE USER IF NOT EXISTS 'monitor'@'172.25.%' IDENTIFIED BY 'monitor123';
GRANT SELECT, REPLICATION CLIENT, PROCESS ON *.* TO 'monitor'@'172.25.%';

-- Root user sudah dibuat oleh Docker dengan akses dari manapun (%)
-- Password root: password123 (dari MYSQL_ROOT_PASSWORD)

FLUSH PRIVILEGES;

-- Wait for master to be ready
SELECT SLEEP(15);

-- Setup replication from master
EOF

    if [ -n "$master_host" ]; then
        echo "CHANGE MASTER TO MASTER_HOST='${master_host}', MASTER_USER='repl', MASTER_PASSWORD='replica123', MASTER_PORT=3306;" >> "$init_file"
        echo "START SLAVE;" >> "$init_file"
    fi

    echo -e "${GREEN}✓ Init file created: $init_file${NC}"
}

# Fungsi untuk menambah master baru
add_master() {
    echo -e "${BLUE}➤ Menambahkan Master baru...${NC}"

    local last_num=$(get_last_number "master")
    local new_num=$((last_num + 1))
    local new_name="mariadb-master${new_num}"
    local last_server_id=$(get_last_server_id)
    local new_server_id=$((last_server_id + 1))
    local new_port=$((3306 + new_num))

    # Tentukan master yang akan direplikasi (master sebelumnya)
    local replicate_from="mariadb-master$((new_num - 1))"
    if [ $new_num -eq 1 ]; then
        replicate_from=""
    fi

    echo "  New Master: master${new_num}"
    echo "  Server ID : ${new_server_id}"
    echo "  Port      : ${new_port}"
    echo "  Replicate : ${replicate_from}"

    # Buat direktori dan init.sql
    create_init_sql "master${new_num}" "$replicate_from"

    # Jalankan container baru
    docker run -d \
        --name "$new_name" \
        --network mariadb-multicluster_mariadb-cluster \
        -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
        -e MYSQL_DATABASE=testdb \
        -e MYSQL_USER=repl \
        -e MYSQL_PASSWORD="${MYSQL_REPL_PASSWORD}" \
        -v "$(pwd)/master${new_num}/data:/var/lib/mysql" \
        -v "$(pwd)/master${new_num}/init:/docker-entrypoint-initdb.d" \
        -p "${new_port}:3306" \
        mariadb:11.4 \
        --bind-address=0.0.0.0 \
        --server-id=${new_server_id} \
        --log-bin=mysql-bin \
        --binlog-format=ROW \
        --max_connections=250 \
        --innodb_buffer_pool_size=2G \
        --innodb_log_file_size=512M \
        --innodb_flush_log_at_trx_commit=1 \
        --innodb_flush_method=O_DIRECT

    echo -e "${GREEN}✓ Master${new_num} berhasil ditambahkan!${NC}"
    echo -e "${YELLOW}➤ Tambahkan ke ProxySQL dengan:${NC}"
    echo "   docker exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin -e \"INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '${new_name}', 3306); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\""
}

# Fungsi untuk menambah slave baru
add_slave() {
    echo -e "${BLUE}➤ Menambahkan Slave baru...${NC}"

    local last_num=$(get_last_number "slave")
    local new_num=$((last_num + 1))
    local new_name="mariadb-slave${new_num}"
    local last_server_id=$(get_last_server_id)
    local new_server_id=$((last_server_id + 1))
    local new_port=$((3308 + new_num))

    # Tentukan master yang akan direplikasi
    # Distribusi: master1 atau master2 bergantian
    local master_num=$(( (new_num % 2) + 1 ))
    local replicate_from="mariadb-master${master_num}"

    echo "  New Slave : slave${new_num}"
    echo "  Server ID : ${new_server_id}"
    echo "  Port      : ${new_port}"
    echo "  Replicate : ${replicate_from}"

    # Buat direktori dan init.sql
    create_init_sql "slave${new_num}" "$replicate_from"

    # Jalankan container baru
    docker run -d \
        --name "$new_name" \
        --network mariadb-multicluster_mariadb-cluster \
        -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
        -e MYSQL_DATABASE=testdb \
        -e MYSQL_USER=repl \
        -e MYSQL_PASSWORD="${MYSQL_REPL_PASSWORD}" \
        -v "$(pwd)/slave${new_num}/data:/var/lib/mysql" \
        -v "$(pwd)/slave${new_num}/init:/docker-entrypoint-initdb.d" \
        -p "${new_port}:3306" \
        mariadb:11.4 \
        --bind-address=0.0.0.0 \
        --server-id=${new_server_id} \
        --log-bin=mysql-bin \
        --binlog-format=ROW \
        --read-only=ON \
        --max_connections=250 \
        --innodb_buffer_pool_size=2G \
        --innodb_log_file_size=512M \
        --innodb_flush_log_at_trx_commit=1 \
        --innodb_flush_method=O_DIRECT

    echo -e "${GREEN}✓ Slave${new_num} berhasil ditambahkan!${NC}"
    echo -e "${YELLOW}➤ Tambahkan ke ProxySQL dengan:${NC}"
    echo "   docker exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin -e \"INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '${new_name}', 3306); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\""
}

# Fungsi untuk list semua nodes
list_nodes() {
    echo -e "${BLUE}➤ Daftar Node MariaDB Cluster:${NC}"
    echo ""
    docker ps --filter "name=mariadb-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# Fungsi untuk remove node
remove_node() {
    local node_name=$1

    if [ -z "$node_name" ]; then
        echo -e "${RED}✖ Error: Nama node harus disebutkan${NC}"
        echo "   Usage: $0 remove-node <node_name>"
        echo "   Contoh: $0 remove-node mariadb-slave5"
        return 1
    fi

    echo -e "${YELLOW}⚠️  Menghapus node: ${node_name}${NC}"

    # Stop dan remove container
    docker stop "$node_name" 2>/dev/null
    docker rm "$node_name" 2>/dev/null

    echo -e "${GREEN}✓ Node ${node_name} berhasil dihapus!${NC}"
    echo -e "${YELLOW}➤ Hapus dari ProxySQL dengan:${NC}"
    echo "   docker exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin -e \"DELETE FROM mysql_servers WHERE hostname='${node_name}'; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;\""
}

########################################
# Performance Mode Functions
########################################

# Set performance mode
set_performance_mode() {
    local mode=$1

    if [ "$mode" != "production" ] && [ "$mode" != "development" ]; then
        echo -e "${RED}✖ Error: Mode harus 'production' atau 'development'${NC}"
        return 1
    fi

    echo -e "${BLUE}➤ Setting performance mode: ${mode}${NC}"
    echo ""

    local settings
    if [ "$mode" = "production" ]; then
        echo -e "${YELLOW}⚠️  PRODUCTION MODE: Durability ON, Speed: Normal${NC}"
        settings="SET GLOBAL innodb_flush_log_at_trx_commit = 2; SET GLOBAL innodb_doublewrite = ON; SET GLOBAL sync_binlog = 1; SET GLOBAL innodb_io_capacity = 2000; SET GLOBAL innodb_io_capacity_max = 4000;"
    else
        echo -e "${YELLOW}🚀 DEVELOPMENT MODE: Speed MAX, Durability OFF${NC}"
        settings="SET GLOBAL innodb_flush_log_at_trx_commit = 0; SET GLOBAL innodb_doublewrite = OFF; SET GLOBAL sync_binlog = 0; SET GLOBAL innodb_io_capacity = 4000; SET GLOBAL innodb_io_capacity_max = 8000;"
    fi

    for container in $(docker ps --filter "name=mariadb-" --format "{{.Names}}"); do
        echo "  Updating: $container"
        docker exec $container mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "$settings" 2>/dev/null
    done

    echo ""
    echo -e "${GREEN}✓ Performance mode set to: ${mode}${NC}"
    echo ""

    if [ "$mode" = "development" ]; then
        echo -e "${YELLOW}⚡ DEVELOPMENT MODE ACTIVE:${NC}"
        echo "  - Write speed: 5-10x faster"
        echo "  - Risk: Data bisa hilang jika crash"
        echo "  - Cocok: Development, testing, bulk import"
    else
        echo -e "${GREEN}🛡️  PRODUCTION MODE ACTIVE:${NC}"
        echo "  - Data safety: HIGH"
        echo "  - Write speed: Normal (aman)"
        echo "  - Cocok: Production, critical data"
    fi
}

# Show current mode
show_current_mode() {
    echo -e "${BLUE}➤ Checking current performance mode...${NC}"
    echo ""

    local container=$(docker ps --filter "name=mariadb-master1" --format "{{.Names}}" | head -1)

    if [ -z "$container" ]; then
        echo -e "${RED}✖ No containers running${NC}"
        return 1
    fi

    docker exec $container mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
        SELECT
            CASE WHEN @@innodb_flush_log_at_trx_commit = 0 THEN 'DEVELOPMENT' ELSE 'PRODUCTION' END as 'Mode',
            @@innodb_flush_log_at_trx_commit as 'flush_log',
            @@innodb_doublewrite as 'doublewrite',
            @@sync_binlog as 'sync_binlog',
            @@innodb_io_capacity as 'io_capacity';
    " 2>/dev/null

    echo ""
    echo -e "${YELLOW}Hint: Use './bench.sh mode production' or './bench.sh mode development'${NC}"
}

# Fungsi untuk reset data - hapus semua folder data
reset_data() {
    echo -e "${YELLOW}⚠️  WARNING: Ini akan menghapus SEMUA data MariaDB cluster!${NC}"
    echo -e "${YELLOW}⚠️  Cluster akan di-reset ke kondisi awal.${NC}"
    echo ""
    read -p "Apakah Anda yakin? (ketik 'YES' untuk konfirmasi): " confirm

    if [ "$confirm" != "YES" ]; then
        echo -e "${BLUE}➤ Reset dibatalkan.${NC}"
        return 0
    fi

    echo ""
    echo -e "${BLUE}➤ Menghentikan semua containers...${NC}"
    docker-compose down

    echo -e "${BLUE}➤ Menghapus data directories...${NC}"

    # Hapus data master
    for dir in master*/data; do
        if [ -d "$dir" ]; then
            echo "  Menghapus: $dir"
            rm -rf "$dir"/*
        fi
    done

    # Hapus data slave
    for dir in slave*/data; do
        if [ -d "$dir" ]; then
            echo "  Menghapus: $dir"
            rm -rf "$dir"/*
        fi
    done

    echo -e "${GREEN}✓ Semua data berhasil dihapus!${NC}"
    echo ""
    echo -e "${YELLOW}➤ Untuk memulai ulang cluster, jalankan:${NC}"
    echo "   docker-compose up -d"
    echo ""
    echo -e "${YELLOW}➤ Atau gunakan:${NC}"
    echo "   $0 reset-and-start  # Reset + start otomatis"
}

# Fungsi untuk reset dan start ulang
reset_and_start() {
    echo -e "${YELLOW}⚠️  WARNING: Ini akan menghapus SEMUA data dan restart cluster!${NC}"
    echo ""
    read -p "Apakah Anda yakin? (ketik 'YES' untuk konfirmasi): " confirm

    if [ "$confirm" != "YES" ]; then
        echo -e "${BLUE}➤ Reset dibatalkan.${NC}"
        return 0
    fi

    echo ""
    echo -e "${BLUE}➤ Menghentikan semua containers...${NC}"
    docker-compose down

    echo -e "${BLUE}➤ Menghapus data directories...${NC}"

    # Hapus data master
    for dir in master*/data; do
        if [ -d "$dir" ]; then
            echo "  Menghapus: $dir"
            rm -rf "$dir"/*
        fi
    done

    # Hapus data slave
    for dir in slave*/data; do
        if [ -d "$dir" ]; then
            echo "  Menghapus: $dir"
            rm -rf "$dir"/*
        fi
    done

    echo -e "${GREEN}✓ Data dihapus!${NC}"
    echo ""
    echo -e "${BLUE}➤ Starting cluster...${NC}"
    docker-compose up -d

    echo ""
    echo -e "${GREEN}✓ Cluster berhasil di-reset dan di-start!${NC}"
    echo -e "${YELLOW}➤ Tunggu ~60 detik untuk inisialisasi selesai.${NC}"
    echo ""
    echo -e "${YELLOW}➤ Cek status dengan:${NC}"
    echo "   docker-compose ps"
    echo "   docker-compose logs -f"
}

########################################
# Help
########################################
show_help() {
    echo "Usage: $0 {prepare|run|cleanup|all|stats|add-master|add-slave|list-nodes|remove-node|mode|show-mode|reset|reset-and-start}"
    echo ""
    echo "Benchmark Commands:"
    echo "  prepare     - Persiapkan database untuk benchmark"
    echo "  run         - Jalankan benchmark test"
    echo "  cleanup     - Bersihkan data benchmark"
    echo "  all         - Jalankan semua (prepare, run, cleanup)"
    echo "  stats       - Tampilkan statistik database"
    echo ""
    echo "Scaling Commands:"
    echo "  add-master  - Tambah master baru secara dinamis"
    echo "  add-slave   - Tambah slave baru secara dinamis"
    echo "  list-nodes  - Tampilkan semua nodes"
    echo "  remove-node <name> - Hapus node tertentu"
    echo ""
    echo "Performance Commands:"
    echo "  mode <production|development> - Set performance mode"
    echo "  show-mode   - Tampilkan mode saat ini"
    echo ""
    echo "Maintenance Commands:"
    echo "  reset       - Hapus semua data folder (perlu konfirmasi)"
    echo "  reset-and-start - Reset data + restart cluster otomatis"
    echo ""
    echo "Examples:"
    echo "  $0 mode development    # Set FAST mode untuk import"
    echo "  $0 mode production     # Set SAFE mode"
    echo "  $0 show-mode           # Cek mode aktif"
    echo "  $0 add-master          # Tambah master3, master4, dst"
    echo "  $0 add-slave           # Tambah slave5, slave6, dst"
    echo "  $0 remove-node mariadb-slave5"
    echo "  $0 reset               # Hapus semua data"
    echo "  $0 reset-and-start     # Reset + auto restart"
}

########################################
# Main Logic
########################################

# Skip dependency check untuk scaling commands
case "$1" in
    add-master|add-slave|list-nodes|remove-node|reset|reset-and-start|mode|show-mode)
        # Tidak perlu sysbench untuk scaling dan maintenance
        ;;
    *)
        check_dependencies
        ;;
esac

case "$1" in
    prepare) prepare ;;
    run) run_test ;;
    cleanup) cleanup ;;
    all)
        prepare
        run_test
        cleanup
        ;;
    stats)
        show_db_stats
        ;;
    add-master)
        add_master
        ;;
    add-slave)
        add_slave
        ;;
    list-nodes)
        list_nodes
        ;;
    remove-node)
        remove_node "$2"
        ;;
    mode)
        if [ -z "$2" ]; then
            echo -e "${RED}✖ Error: Specify mode (production or development)${NC}"
            echo "   Usage: $0 mode <production|development>"
            exit 1
        fi
        set_performance_mode "$2"
        ;;
    show-mode)
        show_current_mode
        ;;
    reset)
        reset_data
        ;;
    reset-and-start)
        reset_and_start
        ;;
    *)
        show_help
        exit 1
        ;;
esac
