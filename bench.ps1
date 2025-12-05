# PowerShell script untuk benchmark dan management MariaDB cluster
# Usage: .\bench.ps1 <command>

# Load environment variables
if (Test-Path ".\.env") {
    Get-Content ".\.env" | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            Set-Variable -Name $matches[1] -Value $matches[2] -Scope Script
        }
    }
}

########################################
# Konfigurasi Database
########################################
$script:DB_HOST = "127.0.0.1"
$script:DB_PORT = "6033"
$script:DB_USER = "root"
$script:DB_PASS = if ($MYSQL_ROOT_PASSWORD) { $MYSQL_ROOT_PASSWORD } else { "password123" }
$script:DB_NAME = "sbtest"

########################################
# Konfigurasi SysBench
########################################
$script:TABLES = 10
$script:TABLE_SIZE = 1000000
$script:THREADS = 16
$script:RUNTIME = 60
$script:REPORT_INTERVAL = 5

########################################
# Direktori Log
########################################
$script:LOG_DIR = ".\logs"
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR | Out-Null
}

########################################
# Fungsi Helper
########################################
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

########################################
# Dynamic Scaling Functions
########################################

function Get-LastNodeNumber {
    param([string]$Type)

    $containers = docker ps -a --format "{{.Names}}" | Where-Object { $_ -match "mariadb-$Type(\d+)" }
    if ($containers) {
        $numbers = $containers | ForEach-Object {
            if ($_ -match "mariadb-$Type(\d+)") { [int]$matches[1] }
        }
        return ($numbers | Measure-Object -Maximum).Maximum
    }
    return 0
}

function Get-LastServerId {
    $maxId = 0
    $containers = docker ps --format "{{.Names}}" | Where-Object { $_ -match "^mariadb-" }

    foreach ($container in $containers) {
        try {
            $serverId = docker exec $container mariadb -uroot -p"$script:DB_PASS" -e "SELECT @@server_id;" 2>$null | Select-Object -Last 1
            if ($serverId -and [int]$serverId -gt $maxId) {
                $maxId = [int]$serverId
            }
        } catch {
            # Skip if error
        }
    }
    return $maxId
}

function New-InitSql {
    param(
        [string]$NodeName,
        [string]$MasterHost = ""
    )

    $initDir = "$NodeName\init"
    $dataDir = "$NodeName\data"
    $initFile = "$initDir\init.sql"

    if (-not (Test-Path $initDir)) {
        New-Item -ItemType Directory -Path $initDir -Force | Out-Null
    }
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    $content = @"
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
GRANT SELECT, REPLICATION CLIENT, PROCESS ON *.* TO 'monitor'@'172.25.%';

FLUSH PRIVILEGES;

-- Enable binlog kembali
SET sql_log_bin=1;

-- Wait for master to be ready
SELECT SLEEP(15);
"@

    if ($MasterHost) {
        $content += @"

-- Setup replication from master
CHANGE MASTER TO MASTER_HOST='$MasterHost', MASTER_USER='repl', MASTER_PASSWORD='replica123', MASTER_PORT=3306;
START SLAVE;
"@
    }

    Set-Content -Path $initFile -Value $content -Encoding UTF8
    Write-ColorOutput "✓ Init file created: $initFile" -Color Green
}

function Add-Master {
    Write-ColorOutput "➤ Menambahkan Master baru..." -Color Cyan

    $lastNum = Get-LastNodeNumber -Type "master"
    $newNum = $lastNum + 1
    $newName = "mariadb-master$newNum"
    $lastServerId = Get-LastServerId
    $newServerId = $lastServerId + 1
    $newPort = 3306 + $newNum

    # Tentukan master yang akan direplikasi
    $replicateFrom = ""
    if ($newNum -gt 1) {
        $replicateFrom = "mariadb-master$($newNum - 1)"
    }

    Write-Host "  New Master: master$newNum"
    Write-Host "  Server ID : $newServerId"
    Write-Host "  Port      : $newPort"
    Write-Host "  Replicate : $replicateFrom"

    # Buat direktori dan init.sql
    New-InitSql -NodeName "master$newNum" -MasterHost $replicateFrom

    # Jalankan container baru
    docker run -d `
        --name $newName `
        --network "mariadb-multicluster_mariadb-cluster" `
        -e "MYSQL_ROOT_PASSWORD=$script:DB_PASS" `
        -e "MYSQL_DATABASE=testdb" `
        -e "MYSQL_USER=repl" `
        -e "MYSQL_PASSWORD=replica123" `
        -v "${PWD}\master${newNum}\data:/var/lib/mysql" `
        -v "${PWD}\master${newNum}\init:/docker-entrypoint-initdb.d" `
        -p "${newPort}:3306" `
        mariadb:11.4 `
        --bind-address=0.0.0.0 `
        --server-id=$newServerId `
        --log-bin=mysql-bin `
        --binlog-format=ROW `
        --max_connections=250 `
        --innodb_buffer_pool_size=2G `
        --innodb_log_file_size=512M `
        --innodb_flush_log_at_trx_commit=1 `
        --innodb_flush_method=O_DIRECT

    Write-ColorOutput "✓ Master$newNum berhasil ditambahkan!" -Color Green
    Write-ColorOutput "➤ Tambahkan ke ProxySQL dengan:" -Color Yellow
    Write-Host "   docker exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin -e `"INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '$newName', 3306); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;`""
}

function Add-Slave {
    Write-ColorOutput "➤ Menambahkan Slave baru..." -Color Cyan

    $lastNum = Get-LastNodeNumber -Type "slave"
    $newNum = $lastNum + 1
    $newName = "mariadb-slave$newNum"
    $lastServerId = Get-LastServerId
    $newServerId = $lastServerId + 1
    $newPort = 3308 + $newNum

    # Distribusi ke master1 atau master2
    $masterNum = ($newNum % 2) + 1
    $replicateFrom = "mariadb-master$masterNum"

    Write-Host "  New Slave : slave$newNum"
    Write-Host "  Server ID : $newServerId"
    Write-Host "  Port      : $newPort"
    Write-Host "  Replicate : $replicateFrom"

    # Buat direktori dan init.sql
    New-InitSql -NodeName "slave$newNum" -MasterHost $replicateFrom

    # Jalankan container baru
    docker run -d `
        --name $newName `
        --network "mariadb-multicluster_mariadb-cluster" `
        -e "MYSQL_ROOT_PASSWORD=$script:DB_PASS" `
        -e "MYSQL_DATABASE=testdb" `
        -e "MYSQL_USER=repl" `
        -e "MYSQL_PASSWORD=replica123" `
        -v "${PWD}\slave${newNum}\data:/var/lib/mysql" `
        -v "${PWD}\slave${newNum}\init:/docker-entrypoint-initdb.d" `
        -p "${newPort}:3306" `
        mariadb:11.4 `
        --bind-address=0.0.0.0 `
        --server-id=$newServerId `
        --log-bin=mysql-bin `
        --binlog-format=ROW `
        --read-only=ON `
        --max_connections=250 `
        --innodb_buffer_pool_size=2G `
        --innodb_log_file_size=512M `
        --innodb_flush_log_at_trx_commit=1 `
        --innodb_flush_method=O_DIRECT

    Write-ColorOutput "✓ Slave$newNum berhasil ditambahkan!" -Color Green
    Write-ColorOutput "➤ Tambahkan ke ProxySQL dengan:" -Color Yellow
    Write-Host "   docker exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin -e `"INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (20, '$newName', 3306); LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;`""
}

function Show-Nodes {
    Write-ColorOutput "➤ Daftar Node MariaDB Cluster:" -Color Cyan
    Write-Host ""
    docker ps --filter "name=mariadb-" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}"
}

function Remove-Node {
    param([string]$NodeName)

    if (-not $NodeName) {
        Write-ColorOutput "✖ Error: Nama node harus disebutkan" -Color Red
        Write-Host "   Usage: .\bench.ps1 remove-node <node_name>"
        Write-Host "   Contoh: .\bench.ps1 remove-node mariadb-slave5"
        return
    }

    Write-ColorOutput "⚠️  Menghapus node: $NodeName" -Color Yellow

    docker stop $NodeName 2>$null
    docker rm $NodeName 2>$null

    Write-ColorOutput "✓ Node $NodeName berhasil dihapus!" -Color Green
    Write-ColorOutput "➤ Hapus dari ProxySQL dengan:" -Color Yellow
    Write-Host "   docker exec proxysql mysql -h127.0.0.1 -P6032 -uadmin -padmin -e `"DELETE FROM mysql_servers WHERE hostname='$NodeName'; LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;`""
}

########################################
# Maintenance Functions
########################################

function Reset-Data {
    Write-ColorOutput "⚠️  WARNING: Ini akan menghapus SEMUA data MariaDB cluster!" -Color Yellow
    Write-ColorOutput "⚠️  Cluster akan di-reset ke kondisi awal." -Color Yellow
    Write-Host ""
    $confirm = Read-Host "Apakah Anda yakin? (ketik 'YES' untuk konfirmasi)"

    if ($confirm -ne "YES") {
        Write-ColorOutput "➤ Reset dibatalkan." -Color Cyan
        return
    }

    Write-Host ""
    Write-ColorOutput "➤ Menghentikan semua containers..." -Color Cyan
    docker-compose down

    Write-ColorOutput "➤ Menghapus data directories..." -Color Cyan

    # Hapus data master
    Get-ChildItem -Directory -Filter "master*" | ForEach-Object {
        $dataPath = Join-Path $_.FullName "data"
        if (Test-Path $dataPath) {
            Write-Host "  Menghapus: $dataPath"
            Remove-Item -Path "$dataPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Hapus data slave
    Get-ChildItem -Directory -Filter "slave*" | ForEach-Object {
        $dataPath = Join-Path $_.FullName "data"
        if (Test-Path $dataPath) {
            Write-Host "  Menghapus: $dataPath"
            Remove-Item -Path "$dataPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-ColorOutput "✓ Semua data berhasil dihapus!" -Color Green
    Write-Host ""
    Write-ColorOutput "➤ Untuk memulai ulang cluster, jalankan:" -Color Yellow
    Write-Host "   docker-compose up -d"
    Write-Host ""
    Write-ColorOutput "➤ Atau gunakan:" -Color Yellow
    Write-Host "   .\bench.ps1 reset-and-start  # Reset + start otomatis"
}

function Reset-AndStart {
    Write-ColorOutput "⚠️  WARNING: Ini akan menghapus SEMUA data dan restart cluster!" -Color Yellow
    Write-Host ""
    $confirm = Read-Host "Apakah Anda yakin? (ketik 'YES' untuk konfirmasi)"

    if ($confirm -ne "YES") {
        Write-ColorOutput "➤ Reset dibatalkan." -Color Cyan
        return
    }

    Write-Host ""
    Write-ColorOutput "➤ Menghentikan semua containers..." -Color Cyan
    docker-compose down

    Write-ColorOutput "➤ Menghapus data directories..." -Color Cyan

    # Hapus data master
    Get-ChildItem -Directory -Filter "master*" | ForEach-Object {
        $dataPath = Join-Path $_.FullName "data"
        if (Test-Path $dataPath) {
            Write-Host "  Menghapus: $dataPath"
            Remove-Item -Path "$dataPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Hapus data slave
    Get-ChildItem -Directory -Filter "slave*" | ForEach-Object {
        $dataPath = Join-Path $_.FullName "data"
        if (Test-Path $dataPath) {
            Write-Host "  Menghapus: $dataPath"
            Remove-Item -Path "$dataPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-ColorOutput "✓ Data dihapus!" -Color Green
    Write-Host ""
    Write-ColorOutput "➤ Starting cluster..." -Color Cyan
    docker-compose up -d

    Write-Host ""
    Write-ColorOutput "✓ Cluster berhasil di-reset dan di-start!" -Color Green
    Write-ColorOutput "➤ Tunggu ~60 detik untuk inisialisasi selesai." -Color Yellow
    Write-Host ""
    Write-ColorOutput "➤ Cek status dengan:" -Color Yellow
    Write-Host "   docker-compose ps"
    Write-Host "   docker-compose logs -f"
}

########################################
# Database Stats
########################################

function Show-DbStats {
    Write-ColorOutput "➤ Menampilkan Statistik Database & InnoDB..." -Color Cyan

    $query = @"
SELECT 'INNODB_BUFFER_POOL_SIZE' AS variable, @@innodb_buffer_pool_size AS value UNION ALL
SELECT 'INNODB_LOG_FILE_SIZE', @@innodb_log_file_size UNION ALL
SELECT 'INNODB_FLUSH_LOG_AT_TRX_COMMIT', @@innodb_flush_log_at_trx_commit UNION ALL
SELECT 'INNODB_FLUSH_METHOD', @@innodb_flush_method UNION ALL
SELECT 'MAX_CONNECTIONS', @@max_connections;
"@

    docker exec mariadb-master1 mariadb -uroot -p"$script:DB_PASS" -e $query 2>$null
    docker exec mariadb-master1 mariadb -uroot -p"$script:DB_PASS" -e "SHOW GLOBAL STATUS LIKE 'Max_used_connections';" 2>$null
}

########################################
# Performance Mode Functions
########################################

function Set-PerformanceMode {
    param([string]$Mode)

    if ($Mode -ne "production" -and $Mode -ne "development") {
        Write-ColorOutput "✖ Error: Mode harus 'production' atau 'development'" -Color Red
        return
    }

    Write-ColorOutput "➤ Setting performance mode: $Mode" -Color Cyan
    Write-Host ""

    $containers = docker ps --filter "name=mariadb-" --format "{{.Names}}"

    if ($Mode -eq "production") {
        Write-ColorOutput "⚠️  PRODUCTION MODE: Durability ON, Speed: Normal" -Color Yellow
        $settings = @"
SET GLOBAL innodb_flush_log_at_trx_commit = 2;
SET GLOBAL innodb_doublewrite = ON;
SET GLOBAL sync_binlog = 1;
SET GLOBAL innodb_io_capacity = 2000;
SET GLOBAL innodb_io_capacity_max = 4000;
"@
    } else {
        Write-ColorOutput "🚀 DEVELOPMENT MODE: Speed MAX, Durability OFF" -Color Yellow
        $settings = @"
SET GLOBAL innodb_flush_log_at_trx_commit = 0;
SET GLOBAL innodb_doublewrite = OFF;
SET GLOBAL sync_binlog = 0;
SET GLOBAL innodb_io_capacity = 4000;
SET GLOBAL innodb_io_capacity_max = 8000;
"@
    }

    foreach ($container in $containers) {
        Write-Host "  Updating: $container" -ForegroundColor Gray
        docker exec $container mariadb -uroot -p"$script:DB_PASS" -e $settings 2>$null
    }

    Write-Host ""
    Write-ColorOutput "✓ Performance mode set to: $Mode" -Color Green
    Write-Host ""

    if ($Mode -eq "development") {
        Write-ColorOutput "⚡ DEVELOPMENT MODE ACTIVE:" -Color Yellow
        Write-Host "  - Write speed: 5-10x faster"
        Write-Host "  - Risk: Data bisa hilang jika crash"
        Write-Host "  - Cocok: Development, testing, bulk import"
    } else {
        Write-ColorOutput "🛡️  PRODUCTION MODE ACTIVE:" -Color Green
        Write-Host "  - Data safety: HIGH"
        Write-Host "  - Write speed: Normal (aman)"
        Write-Host "  - Cocok: Production, critical data"
    }
}

function Show-CurrentMode {
    Write-ColorOutput "➤ Checking current performance mode..." -Color Cyan
    Write-Host ""

    $container = docker ps --filter "name=mariadb-master1" --format "{{.Names}}" | Select-Object -First 1

    if (-not $container) {
        Write-ColorOutput "✖ No containers running" -Color Red
        return
    }

    $result = docker exec $container mariadb -uroot -p"$script:DB_PASS" -e @"
SELECT
    CASE WHEN @@innodb_flush_log_at_trx_commit = 0 THEN 'DEVELOPMENT' ELSE 'PRODUCTION' END as 'Mode',
    @@innodb_flush_log_at_trx_commit as 'flush_log',
    @@innodb_doublewrite as 'doublewrite',
    @@sync_binlog as 'sync_binlog',
    @@innodb_io_capacity as 'io_capacity';
"@ 2>$null

    Write-Host $result
    Write-Host ""
    Write-ColorOutput "Hint: Use 'bench.ps1 mode production' or 'bench.ps1 mode development'" -Color Yellow
}

########################################
# Benchmark Functions (Simplified for Windows)
########################################

function Test-SysBench {
    Write-ColorOutput "ℹ️  Note: SysBench benchmark memerlukan instalasi WSL atau Linux." -Color Yellow
    Write-Host "   Untuk benchmark di Windows, gunakan tools alternatif seperti:"
    Write-Host "   - mysqlslap (included with MySQL/MariaDB client)"
    Write-Host "   - HammerDB"
    Write-Host "   - MySQL Benchmark Suite"
    Write-Host ""
    Write-ColorOutput "   Untuk sekarang, gunakan perintah scaling dan maintenance." -Color Cyan
}

########################################
# Help
########################################

function Show-Help {
    Write-Host "Usage: .\bench.ps1 <command> [arguments]"
    Write-Host ""
    Write-ColorOutput "Scaling Commands:" -Color Cyan
    Write-Host "  add-master          - Tambah master baru secara dinamis"
    Write-Host "  add-slave           - Tambah slave baru secara dinamis"
    Write-Host "  list-nodes          - Tampilkan semua nodes"
    Write-Host "  remove-node <name>  - Hapus node tertentu"
    Write-Host ""
    Write-ColorOutput "Performance Commands:" -Color Cyan
    Write-Host "  mode production     - Set ke PRODUCTION mode (safe, normal speed)"
    Write-Host "  mode development    - Set ke DEVELOPMENT mode (fast, less safe)"
    Write-Host "  show-mode           - Tampilkan mode saat ini"
    Write-Host ""
    Write-ColorOutput "Maintenance Commands:" -Color Cyan
    Write-Host "  reset               - Hapus semua data folder (perlu konfirmasi)"
    Write-Host "  reset-and-start     - Reset data + restart cluster otomatis"
    Write-Host "  stats               - Tampilkan statistik database"
    Write-Host ""
    Write-ColorOutput "Examples:" -Color Yellow
    Write-Host "  .\bench.ps1 mode development              # Set FAST mode untuk import"
    Write-Host "  .\bench.ps1 mode production               # Set SAFE mode"
    Write-Host "  .\bench.ps1 show-mode                     # Cek mode aktif"
    Write-Host "  .\bench.ps1 add-master                    # Tambah master3, master4, dst"
    Write-Host "  .\bench.ps1 add-slave                     # Tambah slave5, slave6, dst"
    Write-Host "  .\bench.ps1 remove-node mariadb-slave5    # Hapus slave5"
    Write-Host "  .\bench.ps1 reset                         # Hapus semua data"
    Write-Host "  .\bench.ps1 reset-and-start               # Reset + auto restart"
    Write-Host "  .\bench.ps1 list-nodes                    # Lihat semua nodes"
    Write-Host "  .\bench.ps1 stats                         # Lihat database stats"
}

########################################
# Main Logic
########################################

$command = $args[0]
$argument = $args[1]

switch ($command) {
    "add-master" {
        Add-Master
    }
    "add-slave" {
        Add-Slave
    }
    "list-nodes" {
        Show-Nodes
    }
    "remove-node" {
        Remove-Node -NodeName $argument
    }
    "mode" {
        if ($argument) {
            Set-PerformanceMode -Mode $argument
        } else {
            Write-ColorOutput "✖ Error: Specify mode (production or development)" -Color Red
            Write-Host "   Usage: .\bench.ps1 mode <production|development>"
        }
    }
    "show-mode" {
        Show-CurrentMode
    }
    "reset" {
        Reset-Data
    }
    "reset-and-start" {
        Reset-AndStart
    }
    "stats" {
        Show-DbStats
    }
    "benchmark" {
        Test-SysBench
    }
    default {
        Show-Help
    }
}
