#!/usr/bin/env python3
"""Owned fixture baseline; no performance threshold/claim from one machine."""
import json
import pathlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

scanner = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix="hygieia-mount-bench-"))
try:
    for i in range(400):
        folder = root / f"directory-{i}"
        folder.mkdir()
        for j in range(10):
            (folder / f"file-{j}.txt").write_bytes(b"x" * 128)
    elapsed = []
    for _ in range(6):
        start = time.monotonic()
        result = subprocess.run([str(scanner), "scan", str(root), "--json"], check=True, capture_output=True, text=True)
        elapsed.append(time.monotonic() - start)
        data = json.loads(result.stdout)
        assert data["logicalSize"] == 512000, data
        assert data["issueCount"] == 0, data
    print(json.dumps({"directories": 401, "files": 4000, "warmup_seconds": elapsed[0], "runs_seconds": elapsed[1:], "median_seconds": statistics.median(elapsed[1:])}, indent=2))
finally:
    shutil.rmtree(root)  # This script owns this unmounted temporary root.
