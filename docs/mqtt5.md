# MQTT 5 support

[中文](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/feat/mqtt5-protocol/docs/mqtt5.zh_CN.md) | **English**

MQTT 5 is opt-in. Set the CLI option --mqtt5-enabled true or set
[protocol] mqtt5_enabled = true. The same TCP, TLS, WS or WSS listener
then accepts MQTT 3.1.1 and MQTT 5 clients. The default remains MQTT 3.1.1.
Disabling new MQTT 5 connections does not delete existing persistent Sessions.

## Protocol behavior

The broker supports QoS 0/1/2, retained messages, wildcard filters, Wills,
Keep Alive and persistent Session resume across both protocol versions.
MQTT 5 adds Clean Start and Session Expiry, Message Expiry, Will Delay,
No Local, Retain As Published, Retain Handling, Subscription Identifier,
Topic Alias, Receive Maximum and Maximum Packet Size. Payload Format
Indicator, Content Type, Response Topic, Correlation Data and ordered User
Properties travel with live, queued and retained messages.

An expiry of zero acknowledges a valid publication without downstream
delivery. If RETAIN is set, it clears the previous retained value. A
persistent Will is saved as armed or pending according to the selected
persistence mode. A temporary Session's armed Will cannot survive a process
crash.

Shared subscriptions are outside this implementation. CONNACK announces
Shared Subscription Available = 0; a shared filter receives SUBACK 9E.
Enhanced Authentication methods receive CONNACK 8C. The broker does not
create Response Information namespaces or redirect clients.

Username/password authentication, Principal-owned Client IDs and topic ACLs
apply to both versions. Use TLS or WSS for credentials.

## Configuration

~~~toml
[server]
listen = "0.0.0.0:1883"

[protocol]
mqtt5_enabled = true
server_receive_maximum = 16
server_keep_alive = -1
topic_alias_maximum = 32
max_property_bytes = 16384
max_user_properties = 64
max_subscription_entries = 256
max_alias_bytes_per_connection = 65536
max_delayed_wills = 1024
max_expiry_work_per_turn = 128
write_timeout_ms = 10000

[persistence]
mode = "strict"
data_dir = "/var/lib/moonbit-mqtt-broker"
~~~

Protocol settings require a restart. Their CLI forms use the --mqtt5-
prefix; --help and --print-effective-config show the complete effective
configuration. When MQTT 5 is enabled, server_receive_maximum must not
exceed the per-Session inbound QoS 2 limit, and max_delayed_wills must not
exceed the combined Session and connection capacity.

## Persistence and upgrades

Off mode keeps state in memory. Snapshot mode restores the latest completed
V5 snapshot and can lose changes in its debounce window after a crash.
Strict mode commits persistent Session, retained, subscription and Will
changes to schema-6 WAL before releasing the corresponding network result.
It also persists cleanup of expired or oversized fresh outbound copies.
A committed MQTT exchange can be retransmitted after a crash; this is not
an application-level exactly-once guarantee.

Legacy V1/V2/V3 snapshots and the legacy strict WAL migrate on first
MQTT 5-enabled startup. Back up the data directory and matching security
configuration first. Older executables cannot read upgraded schema-6 data;
rollback requires restoring the pre-upgrade backup. Corrupt authoritative
files fail startup closed.

Management connection details expose protocol version, peer limits and
current receive/transmit window use. Session and subscription details expose
retention, expiry, Will and subscription options. Status and Prometheus
contain only fixed aggregate version, Will, window and alias counts; payloads,
credentials and User Properties are never metric labels.

Run scripts/verify-mqtt5-docker.sh to check the unit suite and the network
matrix across off, snapshot and strict modes and TCP/TLS/WS/WSS. The test
prints its remote MQTT5_EVIDENCE_DIR. See [compatibility](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/feat/mqtt5-protocol/docs/compatibility.md)
and [persistence](https://github.com/ChaonanShen/moonbit-mqtt-broker/blob/feat/mqtt5-protocol/docs/persistence.md) for other broker guarantees.
