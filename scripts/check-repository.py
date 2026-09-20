#!/usr/bin/env python3
"""Repository-only privacy gate. Reports file paths, never matched values.
Not a substitute for reviewing data provenance or running a secret scanner.
"""
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
try:
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root).decode().split("\0")
except subprocess.CalledProcessError:
    raise SystemExit("Run this gate from an initialized repository.")
issues = []
for name in sorted(set(filter(None, paths))):
    p = root / name
    if name in {"GymLog/Config/Local.xcconfig", "GymLog/project.local.yml", "GymLog/project 2.yml"}:
        issues.append((name, "local deployment configuration must not be published"))
    if not p.is_file():
        continue
    if any(part in {"output", "migration", "Screenshots", "screenshots", "private", "backups", "node_modules"} for part in p.relative_to(root).parts):
        issues.append((name, "private/generated directory"))
    if p.suffix.lower() in {".xlsx", ".xls", ".jpg", ".jpeg", ".heic", ".pdf", ".zip", ".ipa", ".p12", ".pem", ".key", ".p8", ".mobileprovision", ".store", ".sqlite", ".db", ".csv", ".m4a", ".wav"}:
        issues.append((name, "private data or signing artifact"))
    if name.startswith("GymLog/Fixtures/") and name not in {"GymLog/Fixtures/sample_seed.json", "GymLog/Fixtures/README.md"}:
        issues.append((name, "unreviewed fixture"))
    if p.suffix.lower() in {".png", ".ico"} and not name.startswith("GymLog/Resources/Assets.xcassets/"):
        issues.append((name, "unreviewed image"))
    try:
        text = p.read_text()
    except UnicodeError:
        continue
    rules = {
        "private home path": r"/Users/[A-Za-z][^\s\"']*/",
        "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "provider or GitHub token": r"(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{24,})",
        "embedded signing team": r'DEVELOPMENT_TEAM:\s*"[A-Z0-9]{10}"',
    }
    for label, pattern in rules.items():
        if re.search(pattern, text):
            issues.append((name, label))
    if name.endswith("exercise_library_seed.json"):
        data = json.loads(text)
        if data.get("clients") or any(e.get("occurrenceCount", 0) != 0 for e in data["exercises"]):
            issues.append((name, "athlete records or private usage counts"))
    if name.endswith("template_seed.json") and "Synthetic" not in json.loads(text).get("source", ""):
        issues.append((name, "template provenance must be synthetic"))
for name, label in issues:
    print(f"{name}: {label}")
if issues:
    raise SystemExit(1)
print(f"Repository privacy gate passed ({len(set(filter(None, paths)))} files).")
