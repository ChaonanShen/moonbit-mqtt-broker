#!/usr/bin/env python3
"""Keep the MQTT 5 performance gate aligned with the frozen paired-median rule."""
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[2]
aggregate = runpy.run_path(
    str(ROOT / "scripts/run-mqtt5-performance.py")
)["aggregate_paired_rows"]

def row(mode, round_number, ratio, p99=1.0, limit=6.0):
    return {
        "mode": mode,
        "round": round_number,
        "throughput_ratio": ratio,
        "candidate_p99_ms": p99,
        "p99_limit_ms": limit,
        "pass": ratio >= 0.90 and p99 <= limit,
    }

rows = [
    row("off", 1, 0.98), row("off", 2, 1.03), row("off", 3, 1.02),
    row("snapshot", 1, 0.857), row("snapshot", 2, 0.928),
    row("snapshot", 3, 1.091),
    row("strict", 1, 1.00), row("strict", 2, 0.99),
    row("strict", 3, 1.01),
]
assert not rows[3]["pass"]
modes = aggregate(rows)
assert [mode["mode"] for mode in modes] == ["off", "snapshot", "strict"]
assert all(mode["pass"] for mode in modes)
assert abs(modes[1]["throughput_ratio_median"] - 0.928) < 1e-12

slow = [dict(value) for value in rows]
slow[4]["throughput_ratio"] = 0.80
assert not aggregate(slow)[1]["pass"]

late = [dict(value) for value in rows]
for value in late:
    if value["mode"] == "strict":
        value["candidate_p99_ms"] = 12.0
assert not aggregate(late)[2]["pass"]

try:
    aggregate(rows[:-1])
except RuntimeError as error:
    assert "incomplete paired rounds" in str(error)
else:
    raise AssertionError("missing round was accepted")

print("MQTT5_PERFORMANCE_MEDIAN_GATE_PASS")
