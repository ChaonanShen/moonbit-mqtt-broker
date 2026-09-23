#!/usr/bin/env python3
"""Summarize committed WAL batch sizes from a stopped test volume."""
import json
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])
sizes = []
bytes_per_batch = []
for path in sorted(root.glob("wal-*.log")):
    data = path.read_bytes()
    if len(data) < 40 or data[:8] != b"MBMWAL01":
        raise ValueError(f"invalid WAL segment header: {path}")
    offset = 40
    count = 0
    start = offset
    while offset < len(data):
        if offset + 9 > len(data):
            raise ValueError(f"incomplete frame: {path}")
        tag = data[offset]
        length = struct.unpack_from(">I", data, offset + 1)[0]
        end = offset + 5 + length + 4
        if end > len(data):
            raise ValueError(f"incomplete frame body: {path}")
        if tag == 1:
            count += 1
        elif tag == 2:
            if not count:
                raise ValueError(f"empty committed batch: {path}")
            sizes.append(count)
            bytes_per_batch.append(end - start)
            count = 0
            start = end
        else:
            raise ValueError(f"unknown frame: {path}")
        offset = end
    if count:
        raise ValueError(f"uncommitted tail: {path}")
result = {
    "batches": len(sizes),
    "transactions": sum(sizes),
    "transactions_per_batch": sizes,
    "bytes_per_batch": bytes_per_batch,
    "max_transactions_per_batch": max(sizes, default=0),
    "mean_transactions_per_batch": sum(sizes) / len(sizes) if sizes else 0,
}
print(json.dumps(result, indent=2))
