#!/usr/bin/env python3
"""Copy only upload-safe release evidence out of private test directories."""

from pathlib import Path
import shutil
import sys

SAFE_SUFFIXES = {".log", ".txt", ".exit-code", ".json", ".tsv"}
ROOT_FILES = {"artifacts.sha256", "package.zip"}
TEST_DIR_PREFIXES = ("commit-", "transports-", "migration-", "dependency-fetch-")
SAFE_RELOAD_FILES = {
    "reload-metadata.txt",
    "lifecycle-summary.txt", "lifecycle-events.log",
    "tls-summary.txt", "tls-events.log",
    "durability-summary.txt", "durability-events.log",
    "security-off-summary.txt", "security-off-events.log",
    "security-snapshot-summary.txt", "security-snapshot-events.log",
    "security-strict-summary.txt", "security-strict-events.log",
    "limits-summary.txt",
    "shutdown-summary.txt", "shutdown-events.log",
}


def copy_file(source: Path, destination: Path, *, executable: bool = False) -> None:
    if source.is_symlink() or not source.is_file():
        return
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    shutil.copyfile(source, destination)
    destination.chmod(0o755 if executable else 0o644)


def stage(source_root: Path, output_root: Path) -> int:
    output_root.mkdir(parents=True, exist_ok=True, mode=0o755)
    output_root.chmod(0o755)
    copied = 0
    if not source_root.exists():
        return copied
    for run in sorted(source_root.iterdir()):
        if run.is_symlink() or not run.is_dir():
            continue
        for entry in run.iterdir():
            if entry.is_symlink():
                continue
            if entry.is_file() and (
                entry.suffix in SAFE_SUFFIXES or entry.name in ROOT_FILES
            ):
                copy_file(entry, output_root / run.name / entry.name)
                copied += 1
            elif entry.is_dir() and entry.name == "runtime":
                broker = entry / "broker"
                if broker.is_file() and not broker.is_symlink():
                    copy_file(broker, output_root / run.name / "runtime" / "broker",
                              executable=True)
                    copied += 1
            elif entry.is_dir() and entry.name.startswith("reload-"):
                for result in entry.iterdir():
                    if result.name in SAFE_RELOAD_FILES:
                        copy_file(result, output_root / run.name / entry.name / result.name)
                        copied += 1
            elif entry.is_dir() and entry.name.startswith(TEST_DIR_PREFIXES):
                for result in entry.iterdir():
                    if (not result.is_symlink() and result.is_file()
                            and result.suffix in SAFE_SUFFIXES):
                        copy_file(result, output_root / run.name / entry.name / result.name)
                        copied += 1
    for directory in output_root.rglob("*"):
        if directory.is_dir():
            directory.chmod(0o755)
    return copied


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: stage_distribution_evidence.py SOURCE OUTPUT")
    count = stage(Path(sys.argv[1]), Path(sys.argv[2]))
    print(f"STAGED_EVIDENCE_FILES={count}")
