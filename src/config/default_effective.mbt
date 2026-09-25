///|
// Generated from broker --print-effective-config. Keep synchronized with startup defaults.
fn default_effective_config_toml() -> String {
  (
    #|[server]
    #|listen = "127.0.0.1:1883"
    #|max_connections = 128
    #|max_packet_size = 1048576
    #|max_receive_buffer_size = 1048576
    #|max_outbound_queue = 64
    #|max_runtime_events = 512
    #|connect_timeout_ms = 10000
    #|keep_alive_check_interval_ms = 100
    #|max_will_bytes_per_connection = 1048576
    #|max_will_bytes_total = 8388608
    #|max_receive_bytes_total = 16777216
    #|max_runtime_bytes_per_connection = 2097152
    #|max_runtime_bytes_total = 16777216
    #|max_outbound_bytes_per_connection = 4194304
    #|max_outbound_bytes_total = 33554432
    #|max_connection_metadata_bytes_total = 1048576
    #|max_connections_per_ip = 32
    #|max_runtime_events_per_connection = 32
    #|[broker]
    #|max_subscriptions_per_session = 128
    #|max_subscriptions_total = 16384
    #|max_retained_messages = 1024
    #|max_sessions = 1024
    #|max_inflight_per_session = 16
    #|max_inflight_total = 512
    #|max_pending_per_session = 64
    #|max_pending_total = 1024
    #|max_inbound_qos2_per_session = 64
    #|max_inbound_qos2_total = 4096
    #|persistent_session_expiry = "never"
    #|max_session_expirations_per_tick = 128
    #|max_retained_bytes_total = 16777216
    #|max_retained_message_bytes = 1048576
    #|max_inflight_bytes_per_session = 4194304
    #|max_inflight_bytes_total = 33554432
    #|max_pending_bytes_per_session = 8388608
    #|max_pending_bytes_total = 67108864
    #|max_session_state_bytes = 12582912
    #|max_subscription_bytes_per_session = 131072
    #|max_subscription_bytes_total = 8388608
    #|max_session_metadata_bytes_total = 1048576
    #|[persistence]
    #|mode = "off"
    #|data_dir = ""
    #|max_snapshot_bytes = 67108864
    #|snapshot_debounce_ms = 250
    #|snapshot_max_delay_ms = 2000
    #|snapshot_retry_ms = 1000
    #|wal_disk_max_bytes = 1073741824
    #|wal_disk_reserve_bytes = 268435456
    #|[tls]
    #|cert = ""
    #|key = ""
    #|handshake_timeout_ms = 10000
    #|[security]
    #|allow_anonymous = true
    #|password_file = ""
    #|acl_file = ""
    #|auth_workers = 1
    #|auth_queue_limit = 16
    #|auth_timeout_ms = 10000
    #|auth_poll_interval_ms = 5
    #|auth_result_batch_limit = 16
    #|auth_shutdown_grace_ms = 10000
    #|[observability]
    #|system_metrics_interval_ms = 10000
    #|log_format = "text"
    #|log_level = "info"
    #|[management]
    #|enabled = false
    #|listen = "127.0.0.1:9091"
    #|token_file = ""
    #|max_connections = 16
    #|max_header_bytes = 4096
    #|max_header_count = 32
    #|max_response_bytes = 65536
    #|request_timeout_ms = 5000
    #|write_timeout_ms = 2000
    #|snapshot_interval_ms = 1000
    #|snapshot_max_age_ms = 5000
    #|ready_require_snapshot_healthy = false
    #|request_rate = 50
    #|request_burst = 100
    #|connection_rate = 100
    #|connection_burst = 200
    #|details_enabled = false
    #|operations_enabled = false
    #|query_queue_limit = 16
    #|operation_queue_limit = 16
    #|max_operation_records = 256
    #|max_running_operations = 8
    #|operation_timeout_ms = 30000
    #|operation_retention_ms = 900000
    #|max_cursor_records = 256
    #|cursor_ttl_ms = 60000
    #|default_page_size = 50
    #|max_page_size = 100
    #|query_scan_limit = 256
    #|query_timeout_ms = 2000
    #|max_audit_records = 1024
    #|command_rate = 5
    #|command_burst = 10
    #|max_index_bytes = 8388608
    #|max_bytes_total = 8388608
    #|[reload]
    #|enabled = false
    #|manifest_file = ""
    #|material_runtime_dir = ""
    #|prepare_timeout_ms = 30000
    #|max_source_bytes = 16777216
    #|max_generation_bytes = 67108864
    #|max_reconcile_items_per_turn = 64
    #|max_reconcile_bytes_per_turn = 1048576
    #|max_accounts = 4096
    #|max_acl_rules = 4096
    #|[resources]
    #|max_managed_bytes_total = 268435456
    #|control_reserve_bytes = 2097152
    #|max_limiter_metadata_bytes_total = 2097152
    #|max_routing_scratch_bytes = 16777216
    #|max_wal_pending_bytes_total = 33554432
    #|max_snapshot_work_bytes = 100663296
    #|max_auth_request_bytes_total = 2097152
    #|max_auth_workspace_bytes_total = 134217728
    #|max_auth_result_bytes_total = 1048576
    #|[limits]
    #|enabled = true
    #|per_ip_enabled = true
    #|connect_rate_per_ip = 10
    #|connect_burst_per_ip = 20
    #|connect_rate_total = 100
    #|connect_burst_total = 200
    #|auth_rate_per_ip = 5
    #|auth_burst_per_ip = 10
    #|auth_rate_total = 20
    #|auth_burst_total = 40
    #|publish_messages_per_session = 100
    #|publish_messages_burst_per_session = 200
    #|publish_bytes_per_session = 1048576
    #|publish_bytes_burst_per_session = 2097152
    #|publish_messages_total = 5000
    #|publish_messages_burst_total = 10000
    #|publish_bytes_total = 16777216
    #|publish_bytes_burst_total = 33554432
    #|ingress_bytes_per_ip = 4194304
    #|ingress_bytes_burst_per_ip = 8388608
    #|ingress_bytes_total = 33554432
    #|ingress_bytes_burst_total = 67108864
    #|control_packets_per_connection = 1000
    #|control_packets_burst_per_connection = 2000
    #|max_ip_buckets = 4096
    #|idle_ttl_ms = 300000
    #|
  )
}
