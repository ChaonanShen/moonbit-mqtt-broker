#!/usr/bin/env python3
"""Paired MQTT 3.1.1 baseline/candidate measurements plus a separate V5 strict run."""
import hashlib
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()
def port():
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        return server.getsockname()[1]
def rss_sampler(pid, output, stopped):
    with open(output, "w", encoding="utf8") as target:
        while not stopped.is_set():
            try:
                for line in pathlib.Path("/proc", str(pid), "status").read_text().splitlines():
                    if line.startswith("VmRSS:"):
                        target.write(str(time.time()) + "\t" + line.split()[1] + "\n")
                        target.flush()
                        break
            except OSError:
                pass
            stopped.wait(1)

def main():
    baseline = os.environ.get("BASELINE_BROKER")
    candidate = os.environ.get(
        "MQTT5_CANDIDATE_BROKER",
        str(ROOT / "_build/native/debug/build/cmd/broker/broker.exe"),
    )
    if not baseline or not os.access(baseline, os.X_OK):
        raise RuntimeError("BASELINE_BROKER must be an executable remote 0.3.0 broker")
    if not os.access(candidate, os.X_OK):
        raise RuntimeError("candidate broker is not executable")
    warm = int(os.environ.get("PERF_WARM_SECONDS", "10"))
    measure = int(os.environ.get("PERF_MEASURE_SECONDS", "60"))
    repeats = int(os.environ.get("PERF_REPEATS", "3"))
    fixture = os.environ.get("PERF_FIXTURE") == "1"
    if warm < 0 or measure < 1 or repeats < 1:
        raise RuntimeError("invalid warm, measure, or repeat count")
    sha = subprocess.check_output(
        ["git", "-c", f"safe.directory={ROOT}", "rev-parse", "HEAD"],
        cwd=ROOT, text=True,
    ).strip()
    expected = os.environ.get("MQTT5_EXPECTED_SHA")
    if expected and expected != sha:
        raise RuntimeError("candidate SHA changed")
    if expected and subprocess.run(
        ["git", "-c", f"safe.directory={ROOT}", "diff", "--quiet",
         "HEAD", "--", "src", "scripts", "tests/integration", "moon.mod"],
        cwd=ROOT, check=False,
    ).returncode != 0:
        raise RuntimeError("candidate source differs from the expected SHA")
    base = pathlib.Path(os.environ.get(
        "PERF_OUTPUT", str(ROOT / ".local/mqtt5-performance")
    ))
    base.mkdir(parents=True, exist_ok=True)
    run = pathlib.Path(tempfile.mkdtemp(
        prefix="run-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-",
        dir=base,
    ))
    print("RUN_DIR=" + str(run), flush=True)
    metadata = run / "metadata.json"
    metadata.write_text(json.dumps({
        "source_sha": sha, "started_at": utc(),
        "warm_seconds": warm, "measure_seconds": measure, "repeats": repeats,
        "baseline_broker": baseline, "baseline_sha256": digest(baseline),
        "candidate_broker": candidate, "candidate_sha256": digest(candidate),
        "kernel": os.uname().release, "cpu_count": os.cpu_count(),
    }, indent=2) + "\n")
    current = None
    status = 1
    try:
        def run_one(kind, mode, round_number, version, executable, enabled):
            nonlocal current
            name = f"{mode}-{round_number}-{kind}"
            tcp_port = port()
            data_dir = run / (name + ".data")
            data_dir.mkdir(mode=0o700)
            args = [executable, "--listen", f"127.0.0.1:{tcp_port}",
                    "--rate-limits-enabled", "false",
                    "--per-ip-limits-enabled", "false"]
            if mode != "off":
                args += ["--data-dir", str(data_dir), "--persistence-mode", mode]
            if enabled:
                args += ["--mqtt5-enabled", "true"]
            (run / (name + ".command.txt")).write_text(
                subprocess.list2cmdline(args) + "\n")
            with open(run / (name + ".broker.log"), "w", encoding="utf8") as broker_log:
                current = subprocess.Popen(
                    ["stdbuf", "-oL", *args], cwd=ROOT,
                    stdout=broker_log, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                started = time.monotonic()
                while True:
                    if "broker_listening" in (run / (name + ".broker.log")).read_text(
                        encoding="utf8", errors="replace"
                    ):
                        break
                    if current.poll() is not None:
                        raise RuntimeError(name + " broker exited before listen")
                    if time.monotonic() - started > 10:
                        raise RuntimeError(name + " broker listen timeout")
                    time.sleep(0.05)
                stopped = threading.Event()
                sampler = threading.Thread(
                    target=rss_sampler,
                    args=(current.pid, run / (name + ".rss.tsv"), stopped),
                    daemon=True,
                )
                sampler.start()
                with open(run / (name + ".client.log"), "w", encoding="utf8") as client_log:
                    completed = subprocess.run(
                        ["node", "tests/integration/mqtt5_performance.mjs",
                         f"mqtt://127.0.0.1:{tcp_port}", str(version),
                         str(warm), str(measure), str(run / (name + ".json"))],
                        cwd=ROOT, stdout=client_log, stderr=subprocess.STDOUT,
                        timeout=warm + measure + 35,
                    )
                stopped.set()
                sampler.join(timeout=2)
                current.send_signal(signal.SIGTERM)
                try:
                    exit_code = current.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    current.kill()
                    raise RuntimeError(name + " broker shutdown timeout")
                current = None
                if completed.returncode != 0 or exit_code != 0:
                    raise RuntimeError(name + " client or broker failed")
            print("PERF_CASE_PASS " + name, flush=True)
        for mode in ("off", "snapshot", "strict"):
            for round_number in range(1, repeats + 1):
                run_one("baseline", mode, round_number, 4, baseline, False)
                run_one("candidate", mode, round_number, 4, candidate, False)
        run_one("candidate-v5", "strict", 1, 5, candidate, True)
        rows = []
        for mode in ("off", "snapshot", "strict"):
            for round_number in range(1, repeats + 1):
                left = json.loads((run / f"{mode}-{round_number}-baseline.json").read_text())
                right = json.loads((run / f"{mode}-{round_number}-candidate.json").read_text())
                ratio = right["throughput_per_second"] / left["throughput_per_second"]
                p99_limit = max(left["ack_ms_p99"] * 1.25, left["ack_ms_p99"] + 5)
                rows.append({
                    "mode": mode, "round": round_number,
                    "throughput_ratio": ratio,
                    "candidate_p99_ms": right["ack_ms_p99"],
                    "p99_limit_ms": p99_limit,
                    "pass": ratio >= 0.90 and right["ack_ms_p99"] <= p99_limit,
                })
        summary = {
            "source_sha": sha,
            "rows": rows,
            "strict_v5": json.loads((run / "strict-1-candidate-v5.json").read_text()),
            "pass": all(row["pass"] for row in rows),
            "fixture": fixture,
        }
        (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        with open(run / "summary.tsv", "w", encoding="utf8") as output:
            output.write("mode\tround\tthroughput_ratio\tcandidate_p99_ms\tp99_limit_ms\tpass\n")
            for row in rows:
                output.write(
                    f'{row["mode"]}\t{row["round"]}\t{row["throughput_ratio"]:.4f}\t'
                    f'{row["candidate_p99_ms"]:.3f}\t{row["p99_limit_ms"]:.3f}\t'
                    f'{row["pass"]}\n'
                )
        status = 0 if fixture or summary["pass"] else 1
        if fixture:
            print("MQTT5_PERFORMANCE_FIXTURE_PASS")
        else:
            print("MQTT5_PERFORMANCE_PASS" if status == 0 else "MQTT5_PERFORMANCE_FAIL")
    finally:
        if current and current.poll() is None:
            current.kill()
            current.wait(timeout=10)
        record = json.loads(metadata.read_text())
        try:
            end_sha = subprocess.check_output(
                ["git", "-c", f"safe.directory={ROOT}", "rev-parse", "HEAD"],
                cwd=ROOT, text=True,
            ).strip()
            end_digest = digest(candidate)
            record["end_source_sha"] = end_sha
            record["end_candidate_sha256"] = end_digest
            if end_sha != sha or end_digest != record["candidate_sha256"]:
                record["candidate_changed"] = True
                if status == 0:
                    status = 97
        except Exception:
            record["candidate_identity_unavailable"] = True
            if status == 0:
                status = 97
        record["completed_at"] = utc()
        record["exit_code"] = status
        metadata.write_text(json.dumps(record, indent=2) + "\n")
        (run / "exit-code.txt").write_text(str(status) + "\n")
    return status

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("MQTT5_PERFORMANCE_ERROR " + str(error), file=sys.stderr)
        sys.exit(1)
