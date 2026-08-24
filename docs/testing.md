# Testing

The supported acceptance path is the pinned Ubuntu 24.04 Linux/amd64 Docker
image. Run the complete cumulative gate with:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/m5-verify-docker.sh
```

M5 retains the 186-test M4 MoonBit baseline and adds external release gates.
The verifier first runs every M0–M4 gate, then formatting, Native
check/test/build, protocol/reference matrices, stability, examples,
documentation checks, and clean-room package auditing. Important workloads are:

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

Unit tests exhaustively truncate golden Disk V1 at every byte offset, mutate
envelope fields/checksum/UTF-8/counts/values, and inject each store save failure
point. Writer tests cover latest-wins overwrite, fixed retry deadlines, degraded
recovery, and drain. Router tests compare snapshot/revision before and after all
state transition families.

For a release candidate, run `scripts/m5-verify-docker.sh` three consecutive
times against the same image and source tree, then run the extended profile
once with `M5_SOAK=1`. Test count and exact gates must be identical. The
extended profile uses the same runner and fixed workload ordering, with 100,000
publications, ten minutes of mixed connected activity, and 25 restart rounds.
