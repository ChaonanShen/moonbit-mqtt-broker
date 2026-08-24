# Testing

The supported acceptance path is the pinned Ubuntu 24.04 Linux/amd64 Docker
image. Run the complete cumulative gate with:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/m11-verify-docker.sh
```

M11 retains every prior protocol/stability/release/shutdown gate and adds TLS,
security, Session expiry, observability, and TOML process coverage. It first
runs every M0–M10 gate, then formatting, Native
check/test/build, protocol/reference matrices, stability, examples,
documentation checks, clean-room package auditing, and M6 shutdown recovery.
Important workloads are:

- `m4_restart.sh`: three Broker processes, MQTT.js, 20 persistent clients,
  Retained/Will, offline QoS 1, raw unacknowledged inflight DUP and Packet IDs,
  and clean-session deletion;
- `m4_crash.sh`: committed-main SHA preservation, stale-temp removal, corrupt
  main before listen, FIFO rejection, and `0700`/`0600` permissions;
- `m4_interop.sh`: Mosquitto retained and persistent offline restart delivery;
- `m5_protocol_matrix.sh`: the final MQTT 3.1.1 support contract;
- `m5_reference_diff.sh`: normalized MoonBit/Mosquitto/Aedes common behavior;
- `m5_stability.sh`: 100 clients, 10,000 QoS 0, 10×100 offline QoS 1,
  slow-consumer isolation, churn, resource bounds, and committed restarts;
- `m5_release_smoke.sh`: side-effect-free CLI help/version and all examples.
- `m6_shutdown.sh`: a 60-second uncommitted debounce window, SIGTERM/SIGINT
  final Snapshot recovery, persistent offline QoS 1, retained state, active
  Will suppression, and memory-only shutdown.
- `m7_tls.sh`: startup rejection for incomplete, malformed, mismatched, unsafe,
  or symlinked credentials; MQTT.js and Mosquitto TLS; wrong-CA and plaintext
  rejection; handshake timeout; 100 concurrent clients; retained, persistent
  Session/offline QoS 1, restart recovery, and shutdown.
- `m8_security.sh`: Argon2id, negative authentication, partial ACL SUBACK,
  publish/retained/Will denial, `$SYS` write protection, Principal ownership,
  V1 migration, TLS, and restart.
- `m9_session_expiry.sh`: default-never compatibility, exact/reset timing,
  active exclusion, bounded sweeps, and persisted deletion after restart.
- `m10_observability.sh`: complete `$SYS` metrics, feedback isolation,
  TLS/auth/ACL counters, explicit ACL, JSON fields, levels, and redaction.
- `m11_config.sh`: maintained TOML parsing, unknown/duplicate rejection,
  CLI precedence, side-effect-free checking, redacted output, and configured
  TLS/auth startup.

Unit tests exhaustively truncate golden Disk V1/V2 at every byte offset, mutate
envelope fields/checksum/UTF-8/counts/values, and inject each store save failure
point. Writer tests cover latest-wins overwrite, fixed retry deadlines, degraded
recovery, and drain. Router tests compare snapshot/revision before and after all
state transition families.

For a release candidate, run `scripts/m11-verify-docker.sh` three consecutive
times against the same image and source tree, then run the extended profile
once with `M5_SOAK=1`. Test count and exact gates must be identical. The
extended profile uses the same runner and fixed workload ordering, with 100,000
publications, ten minutes of mixed connected activity, and 25 restart rounds.
`scripts/m11-release-gate.sh` automates those four runs, twenty SIGTERM
final-snapshot/restart cycles, secret/runtime-artifact scanning, and the
clean-room package audit.
