#!/bin/sh
# Generate ProxySQL config with environment variable substitution

cat > /etc/proxysql.cnf <<EOF
datadir = "/var/lib/proxysql";
errorlog = "/var/lib/proxysql/proxysql.log";

admin_variables =
{
	admin_credentials = "admin:admin";
	mysql_ifaces = "0.0.0.0:6032";
};

mysql_variables =
{
	threads = 8;
	max_connections = 4096;
	default_query_delay = 0;
	default_query_timeout = 36000000;
	have_compress = false;
	poll_timeout = 100;
	interfaces = "0.0.0.0:6033";
	default_schema = "information_schema";
	stacksize = 1048576;
	server_version = "5.5.30";
	connect_timeout_server = 3000;
	connect_timeout_server_max = 10000;
	monitor_username = "${MONITOR_USER:-monitor}";
	monitor_password = "${MONITOR_PASSWORD}";
	monitor_history = 60000;
	monitor_connect_interval = 5000;
	monitor_ping_interval = 3000;
	monitor_read_only_interval = 1000;
	monitor_read_only_timeout = 500;
	monitor_replication_lag_interval = 5000;
	monitor_replication_lag_timeout = 1000;
	ping_interval_server_msec = 3000;
	ping_timeout_server = 200;
	commands_stats = true;
	sessions_sort = true;
	connect_retries_on_failure = 2;
	connection_max_age_ms = 0;
	free_connections_pct = 50;
	multiplexing = true;
	query_cache_size_MB = 256;
	wait_timeout = 28800000;
	default_charset = "utf8mb4";
	init_connect = "";
	client_found_rows = true;
	auto_increment_delay_multiplex = 0;
	eventslog_filename = "";
	eventslog_default_log = 0;
	eventslog_format = 1;
	auditlog_filename = "";
	session_idle_ms = 100;
	client_session_track_gtid = 2;
	threshold_query_length = 524288;
	threshold_resultset_size = 4194304;
};

mysql_servers = (
	{ address = "mariadb-master1"; port = 3306; hostgroup = 10; max_connections = 500; weight = 1000; max_replication_lag = 0; use_ssl = 0; max_latency_ms = 500; comment = "master1"; },
	{ address = "mariadb-master2"; port = 3306; hostgroup = 10; max_connections = 500; weight = 1000; max_replication_lag = 0; use_ssl = 0; max_latency_ms = 500; comment = "master2"; },
	{ address = "mariadb-slave1"; port = 3306; hostgroup = 20; max_connections = 500; weight = 1000; max_replication_lag = 30; use_ssl = 0; max_latency_ms = 500; comment = "slave1"; },
	{ address = "mariadb-slave2"; port = 3306; hostgroup = 20; max_connections = 500; weight = 1000; max_replication_lag = 30; use_ssl = 0; max_latency_ms = 500; comment = "slave2"; },
	{ address = "mariadb-slave3"; port = 3306; hostgroup = 20; max_connections = 500; weight = 1000; max_replication_lag = 30; use_ssl = 0; max_latency_ms = 500; comment = "slave3"; },
	{ address = "mariadb-slave4"; port = 3306; hostgroup = 20; max_connections = 500; weight = 1000; max_replication_lag = 30; use_ssl = 0; max_latency_ms = 500; comment = "slave4"; }
);

mysql_users = (
	{ username = "root"; password = "${MYSQL_ROOT_PASSWORD}"; default_hostgroup = 10; transaction_persistent = 1; max_connections = 2000; fast_forward = 0; },
	{ username = "${MYSQL_REPL_USER:-repl}"; password = "${MYSQL_REPL_PASSWORD}"; default_hostgroup = 10; max_connections = 500; fast_forward = 1; }
);

mysql_query_rules = (
	{ rule_id = 1; active = 1; match_digest = "^SELECT.*FOR UPDATE"; destination_hostgroup = 10; apply = 1; },
	{ rule_id = 2; active = 1; match_digest = "^SELECT.*"; destination_hostgroup = 20; apply = 1; cache_ttl = 5000; },
	{ rule_id = 3; active = 1; match_digest = "^INSERT.*|^UPDATE.*|^DELETE.*|^REPLACE.*"; destination_hostgroup = 10; apply = 1; }
);
EOF

exec /usr/bin/proxysql -f -c /etc/proxysql.cnf --idle-threads
