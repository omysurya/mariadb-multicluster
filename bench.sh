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
# Help
########################################
show_help() {
    echo "Usage: $0 {prepare|run|cleanup|all|stats}"
}

########################################
# Main Logic
########################################
check_dependencies

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
    *)
        show_help
        exit 1
        ;;
esac
