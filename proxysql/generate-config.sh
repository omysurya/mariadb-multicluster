#!/bin/bash

cat > /etc/proxysql.cnf <<EOF
datadir="/var/lib/proxysql"

admin_variables=
{
    admin_credentials="admin:admin;${MONITOR_USER}:${MONITOR_PASSWORD}"
    mysql_ifaces="0.0.0.0:6032"
    refresh_interval=2000
    web_enabled=true
    web_port=6080
}

mysql_variables=
{
    threads=8
    max_connections=2048
    default_query_delay=0
    default_query_timeout=36000000
    have_compress=true
    poll_timeout=2000
    interfaces="0.0.0.0:6033"
    default_schema="testdb"
    stacksize=1048576
    server_version="5.7.28"
    connect_timeout_server=3000
    monitor_username="${MONITOR_USER}"
    monitor_password="${MONITOR_PASSWORD}"
    monitor_history=600000
    monitor_connect_interval=60000
    monitor_ping_interval=10000
    monitor_read_only_interval=1500
    monitor_read_only_timeout=500
    ping_interval_server_msec=120000
    ping_timeout_server=500
    commands_stats=true
    sessions_sort=true
    connect_retries_on_failure=3
}

mysql_servers=
(
    # Master1 - Primary Write Server (HG10)
    {
        address="172.25.0.10"
        port=3306
        hostgroup=10
        max_connections=500
        max_replication_lag=10
        weight=1000
        comment="Master1-Primary-Writer"
    },
    # Master2 - Hot Standby Backup (HG15)
    {
        address="172.25.0.11"
        port=3306
        hostgroup=15
        max_connections=500
        max_replication_lag=10
        weight=1000
        comment="Master2-Hot-Standby"
    },
    # Read Replicas (HG20)
    {
        address="172.25.0.20"
        port=3306
        hostgroup=20
        max_connections=300
        max_replication_lag=30
        weight=1000
        comment="Slave1-ReadReplica"
    },
    {
        address="172.25.0.21"
        port=3306
        hostgroup=20
        max_connections=300
        max_replication_lag=30
        weight=1000
        comment="Slave2-ReadReplica"
    },
    {
        address="172.25.0.22"
        port=3306
        hostgroup=20
        max_connections=300
        max_replication_lag=30
        weight=1000
        comment="Slave3-ReadReplica"
    },
    {
        address="172.25.0.23"
        port=3306
        hostgroup=20
        max_connections=300
        max_replication_lag=30
        weight=1000
        comment="Slave4-ReadReplica"
    }
)

mysql_users=
(
    {
        username = "root"
        password = "${MYSQL_ROOT_PASSWORD}"
        default_hostgroup = 10
        max_connections=500
        default_schema="testdb"
        active = 1
        transaction_persistent = 1
    },
    {
        username = "${MYSQL_REPL_USER}"
        password = "${MYSQL_REPL_PASSWORD}"
        default_hostgroup = 20
        max_connections=200
        default_schema="testdb"
        active = 1
    }
)

mysql_query_rules=
(
    # Rule 1: DDL to Master1 (HG10)
    {
        rule_id=1
        active=1
        match_pattern="^CREATE|^ALTER|^DROP|^TRUNCATE|^RENAME"
        destination_hostgroup=10
        apply=1
        comment="DDL to Master1-HG10"
    },
    # Rule 2: SELECT FOR UPDATE to Master1 (HG10)
    {
        rule_id=2
        active=1
        match_pattern="^SELECT.*FOR UPDATE"
        destination_hostgroup=10
        apply=1
        comment="SELECT FOR UPDATE to Master1-HG10"
    },
    # Rule 3: DML to Master1 (HG10)
    {
        rule_id=3
        active=1
        match_pattern="^INSERT|^UPDATE|^DELETE|^REPLACE|^LOAD DATA"
        destination_hostgroup=10
        apply=1
        comment="DML to Master1-HG10"
    },
    # Rule 4: Transactions to Master1 (HG10)
    {
        rule_id=4
        active=1
        match_pattern="^BEGIN|^START TRANSACTION|^COMMIT|^ROLLBACK"
        destination_hostgroup=10
        apply=1
        comment="Transactions to Master1-HG10"
    },
    # Rule 5: Session commands to Master1 (HG10)
    {
        rule_id=5
        active=1
        match_pattern="^SET|^USE|^SHOW"
        destination_hostgroup=10
        apply=1
        comment="Session commands to Master1-HG10"
    },
    # Rule 100: SELECT to Slaves (HG20)
    {
        rule_id=100
        active=1
        match_pattern="^SELECT"
        destination_hostgroup=20
        apply=1
        comment="SELECT to Slaves-HG20"
    }
)

mysql_replication_hostgroups=
(
    {
        writer_hostgroup=10
        reader_hostgroup=20
        check_type="read_only"
        comment="Master1-HG10 to Slaves-HG20"
    }
)
EOF

# Wait for databases to be ready
echo "Waiting for databases to be ready..."
sleep 30

# Start ProxySQL
exec proxysql -f -c /etc/proxysql.cnf
