#!/usr/bin/env python3
"""Opt-in macOS integration check; creates and mounts only its own APFS image.

Usage: python3 Tests/Integration/volume_boundary_smoke.py .build/debug/hygieia
Never removes a fixture while its mount is still attached.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

scanner = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix="hygieia-volume-smoke-"))
scan_root = root / "selected"
scan_root.mkdir()
mount = scan_root / "mounted"
mount.mkdir()
image = root / "fixture.dmg"
mounted = False


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout


def scan(path):
    return json.loads(run(str(scanner), "scan", str(path), "--json", "--top", "50"))


try:
    run("hdiutil", "create", "-size", "64m", "-fs", "APFS", "-volname", "HygieiaFixture", str(image))
    mounted = True  # Fail closed even if attach reports an error after mounting.
    run("hdiutil", "attach", "-nobrowse", "-mountpoint", str(mount), str(image))
    (mount / "inside.txt").write_text("owned fixture", encoding="utf-8")
    (scan_root / "outside.txt").write_text("outside", encoding="utf-8")
    outer = scan(scan_root)
    assert outer["issueCount"] >= 1, outer
    assert not any("inside.txt" in item["path"] for item in outer["top"]), outer
    assert outer["logicalSize"] == 7, outer
    direct = scan(mount)
    assert any(item["path"] == "inside.txt" for item in direct["top"]), direct
    run("hdiutil", "detach", str(mount))
    mounted = False
    mounted = True
    run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image))
    readonly = scan(mount)
    assert any(item["path"] == "inside.txt" for item in readonly["top"]), readonly
    print("PASS: real APFS mount boundary, explicit mounted-root scan, read-only mounted-root scan")
finally:
    if mounted:
        try:
            run("hdiutil", "detach", str(mount))
            mounted = False
        except subprocess.CalledProcessError:
            print(f"Fixture left mounted; no cleanup attempted: {root}", file=sys.stderr)
    if not mounted:
        shutil.rmtree(root)
