#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 4 ]]; then
  echo "usage: $0 SOURCE_DIR VERSION_DIR CONFIG_TARGET MANIFEST_TARGET" >&2
  exit 2
fi
python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tomllib

source, version, config_target, manifest_target = map(Path, sys.argv[1:])
for label, path in (("VERSION_DIR", version), ("CONFIG_TARGET", config_target),
                    ("MANIFEST_TARGET", manifest_target)):
    if not path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise SystemExit(f"{label} must be an absolute normalized path")
if not source.is_dir() or source.is_symlink():
    raise SystemExit("SOURCE_DIR must be a regular directory")
if version.exists() or version.is_symlink():
    raise SystemExit("VERSION_DIR already exists")
if not version.parent.is_dir():
    raise SystemExit("VERSION_DIR parent must exist")
if source.resolve() == version.resolve(strict=False):
    raise SystemExit("source and version directory must differ")
for parent, dirs, files in os.walk(source, followlinks=False):
    for name in dirs + files:
        path = Path(parent) / name
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise SystemExit(f"unsafe source entry: {path}")
stage = version.parent / (f".{version.name}.tmp-{os.getpid()}")
if stage.exists():
    raise SystemExit("staging directory already exists")
try:
    shutil.copytree(source, stage, symlinks=False)
    candidate = stage / "config.toml"
    if not candidate.is_file():
        raise SystemExit("SOURCE_DIR needs config.toml")
    raw = candidate.read_bytes()
    if len(raw) > 1048576:
        raise SystemExit("config.toml exceeds 1 MiB")
    try:
        config = tomllib.loads(raw.decode("utf-8"))
    except (UnicodeError, tomllib.TOMLDecodeError) as error:
        raise SystemExit(f"invalid config.toml: {error}")
    reload_section = config.get("reload", {})
    if reload_section.get("enabled") is not True:
        raise SystemExit("config.toml must enable reload")
    if reload_section.get("manifest_file") != str(manifest_target):
        raise SystemExit("reload.manifest_file must match MANIFEST_TARGET")
    materials = [("config", None, config_target, candidate)]
    security = config.get("security", {})
    for role, key in (("passwords", "password_file"), ("acl", "acl_file")):
        path = security.get(key)
        if path:
            materials.append((role, None, Path(path), None))
    listeners = config.get("listeners", [])
    if listeners:
        if not isinstance(listeners, list):
            raise SystemExit("listeners must be a table array")
        for listener in listeners:
            if listener.get("transport") in ("tls", "wss"):
                listener_id = listener.get("id")
                if not isinstance(listener_id, str) or not listener_id:
                    raise SystemExit("TLS listener requires an ID")
                for role, key in (("mqtt_cert", "tls_cert"),
                                  ("mqtt_key", "tls_key")):
                    materials.append((role, listener_id, Path(listener[key]), None))
    else:
        tls = config.get("tls", {})
        if tls.get("cert") or tls.get("key"):
            materials.append(("mqtt_cert", "mqtt", Path(tls["cert"]), None))
            materials.append(("mqtt_key", "mqtt", Path(tls["key"]), None))
    if len(materials) > 35:
        raise SystemExit("too many bundle materials")
    used = set()
    entries = []
    for role, listener_id, target, staged in materials:
        identity = (role, listener_id)
        if identity in used:
            raise SystemExit("duplicate material role")
        used.add(identity)
        if not target.is_absolute() or ".." in target.parts or "." in target.parts:
            raise SystemExit(f"{role} path must be absolute and normalized")
        if staged is None:
            try:
                relative = target.relative_to(version)
            except ValueError:
                raise SystemExit(f"{role} path must be inside VERSION_DIR")
            staged = stage / relative
        if not staged.is_file() or staged.is_symlink():
            raise SystemExit(f"{role} source is unavailable")
        mode = staged.stat().st_mode
        if role in ("passwords", "mqtt_key") and mode & 0o077:
            raise SystemExit(f"{role} must not grant group/other permissions")
        data = staged.read_bytes()
        if len(data) > 1048576:
            raise SystemExit(f"{role} exceeds 1 MiB")
        entries.append((role, listener_id, str(target),
                        hashlib.sha256(data).hexdigest()))
    lines = ["version = 1"]
    for role, listener_id, target, digest in entries:
        lines.extend(("[[materials]]", f"role = {json.dumps(role)}"))
        if listener_id is not None:
            lines.append(f"listener_id = {json.dumps(listener_id)}")
        lines.extend((f"path = {json.dumps(target)}",
                      f"sha256 = {json.dumps(digest)}"))
    manifest = stage / "manifest.toml"
    if manifest.exists():
        raise SystemExit("SOURCE_DIR must not contain manifest.toml")
    fd = os.open(manifest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write("\n".join(lines) + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.rename(stage, version)
    print(version / "config.toml")
    print(version / "manifest.toml")
finally:
    if stage.exists():
        shutil.rmtree(stage)
PY

