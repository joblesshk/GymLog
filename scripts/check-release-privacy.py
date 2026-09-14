#!/usr/bin/env python3
"""Check the actual archive, including embedded frameworks, before uploading."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
if not str(info.get("NSMicrophoneUsageDescription", "")).strip():
    raise SystemExit("Release privacy check failed: microphone purpose string is missing.")

bundles = [app] + list(app.rglob("*.framework")) + list(app.rglob("*.appex"))
for bundle in bundles:
    metadata = bundle / "Info.plist"
    if not metadata.exists():
        continue
    executable = plistlib.loads(metadata.read_bytes()).get("CFBundleExecutable")
    if not executable:
        continue
    binary = bundle / executable
    dependencies = subprocess.check_output(["xcrun", "otool", "-L", str(binary)], text=True)
    symbols = subprocess.check_output(["xcrun", "nm", "-u", str(binary)], text=True)
    if "Speech.framework/" in dependencies or "SFSpeech" in symbols:
        raise SystemExit(
            f"Release privacy check failed: {bundle.name} still references Apple Speech. "
            "GymLog cloud-only releases must remove these references; if Apple Speech "
            "is intentionally restored, audit its usage and purpose string first."
        )
print(f"Release privacy check passed: {len(bundles)} bundles, microphone purpose present, no Apple Speech dependency.")
