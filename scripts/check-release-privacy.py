#!/usr/bin/env python3
"""Check the actual archive, including embedded frameworks, before uploading."""
import pathlib
import json
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
# GYMLOG_CLOUD_AI = YES builds carry the microphone purpose string; NO builds carry neither it nor
# microphone code, and the privacy manifest must match whichever was built.
cloud_ai = bool(str(info.get("NSMicrophoneUsageDescription", "")).strip())
if "NSMicrophoneUsageDescription" in info and not cloud_ai:
    raise SystemExit("Release privacy check failed: microphone purpose string is present but empty.")

manifest = app / "PrivacyInfo.xcprivacy"
declared = {entry.get("NSPrivacyCollectedDataType") for entry in
            plistlib.loads(manifest.read_bytes()).get("NSPrivacyCollectedDataTypes", [])} if manifest.exists() else set()
cloud_types = {"NSPrivacyCollectedDataTypeAudioData", "NSPrivacyCollectedDataTypeOtherUserContent",
               "NSPrivacyCollectedDataTypeFitness", "NSPrivacyCollectedDataTypeHealth",
               "NSPrivacyCollectedDataTypeDeviceID"}
if cloud_ai and cloud_types - declared:
    raise SystemExit(f"Release privacy check failed: cloud AI build, but the privacy manifest does not declare "
                     f"{', '.join(sorted(cloud_types - declared))}.")
if not cloud_ai and declared:
    raise SystemExit(f"Release privacy check failed: build without cloud AI still declares collected data "
                     f"{', '.join(sorted(declared))}; App Store answers would be wrong.")

# Inspect the actual shipping resources, not just the source target settings.
for path in app.rglob("*"):
    if path.is_file() and (path.suffix.lower() in {".store", ".sqlite", ".db", ".xlsx", ".xls", ".csv", ".gymlogshare"}
                           or path.name in {"sample_seed.json", "gymlog_seed.json"}):
        raise SystemExit(f"Release privacy check failed: unexpected data file {path.name}.")
seed_path = app / "exercise_library_seed.json"
if seed_path.exists():
    seed = json.loads(seed_path.read_bytes())
    if seed.get("clients") or any(e.get("occurrenceCount", 0) != 0 for e in seed.get("exercises", [])):
        raise SystemExit("Release privacy check failed: exercise seed contains athlete data or usage counts.")

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
    if not cloud_ai and ("AVAudioApplication" in symbols or "AVAudioEngine" in symbols):
        raise SystemExit(f"Release privacy check failed: {bundle.name} has microphone code but no purpose string.")
mode = "cloud AI with its five data declarations" if cloud_ai else "no cloud AI, no microphone code, no collected data"
print(f"Release privacy check passed: {len(bundles)} bundles, {mode}, no Apple Speech dependency.")
