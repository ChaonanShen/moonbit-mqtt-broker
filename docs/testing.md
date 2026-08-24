# Testing

The supported acceptance path is the pinned Ubuntu 24.04 Linux/amd64 Docker
image. Run the complete cumulative gate with:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/m4-verify-docker.sh
```

M4 currently has 186 MoonBit test blocks. The verifier first runs every M0–M3
gate, then formatting, Native check/test/build, persistence exact-name gates,
and package dependency audits. It finally runs:

- `m4_restart.sh`: three Broker processes, MQTT.js, 20 persistent clients,
  Retained/Will, offline QoS 1, raw unacknowledged inflight DUP and Packet IDs,
  and clean-session deletion;
- `m4_crash.sh`: committed-main SHA preservation, stale-temp removal, corrupt
  main before listen, FIFO rejection, and `0700`/`0600` permissions;
- `m4_interop.sh`: Mosquitto retained and persistent offline restart delivery.

Unit tests exhaustively truncate golden Disk V1 at every byte offset, mutate
envelope fields/checksum/UTF-8/counts/values, and inject each store save failure
point. Writer tests cover latest-wins overwrite, fixed retry deadlines, degraded
recovery, and drain. Router tests compare snapshot/revision before and after all
state transition families.

For a release candidate, run `scripts/m4-verify-docker.sh` three consecutive
times against the same image and source tree. Test count and integration output
must be identical.
