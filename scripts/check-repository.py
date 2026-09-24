#!/usr/bin/env python3
"""Repository-only privacy gate. Reports file paths, never matched values.
Not a substitute for reviewing data provenance or running a secret scanner.
"""
import json
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
# Optional, never committed: one private term per line (client names, real
# bundle IDs, team IDs). Matched case-insensitively; CI simply has no file.
terms_path = pathlib.Path(os.environ.get("GYMLOG_PRIVATE_TERMS", "~/.config/gymlog/private-terms.txt")).expanduser()
private_terms = []
if terms_path.is_file():
    private_terms = [line.strip().lower() for line in terms_path.read_text().splitlines() if line.strip() and not line.startswith("#")]
try:
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root).decode().split("\0")
except subprocess.CalledProcessError:
    raise SystemExit("Run this gate from an initialized repository.")
issues = []
for name in sorted(set(filter(None, paths))):
    p = root / name
    if name in {"GymLog/Config/Local.xcconfig", "GymLog/project.local.yml", ".claude/launch.json", ".claude/settings.local.json"}:
        issues.append((name, "local deployment configuration must not be published"))
    if any(re.search(r" \d+(\.[^.]+)?$", part) for part in pathlib.PurePath(name).parts):
        issues.append((name, "sync-conflict duplicate"))
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
        "deployed Worker hostname": r"https?://[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev\b",
        "private home path": r"/Users/[A-Za-z][^\s\"']*/",
        "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "provider or GitHub token": r"(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{24,})",
        "embedded signing team": r'DEVELOPMENT_TEAM\s*[:=]\s*"?(?=[A-Z]*\d)[A-Z0-9]{10}\b',
        "Apple team ID": r"(?:Team ID|team|团队|團隊)\s*[`'\":：]?\s*(?=[A-Z]*\d)[A-Z0-9]{10}\b",
    }
    for label, pattern in rules.items():
        if re.search(pattern, text):
            issues.append((name, label))
    if name == "GymLog/Config/Build.xcconfig":
        configured = re.search(r"^GYMLOG_RELAY_BASE_URL\s*=\s*(.+)$", text, re.MULTILINE)
        if not configured or configured.group(1).strip() != "https:/$()/relay.example.invalid":
            issues.append((name, "shared build configuration must use the disabled example endpoint"))
    lowered = text.lower()
    if any(term in lowered for term in private_terms):
        issues.append((name, "private term"))
    if name.endswith("exercise_library_seed.json"):
        data = json.loads(text)
        if data.get("clients") or any(e.get("occurrenceCount", 0) != 0 for e in data["exercises"]):
            issues.append((name, "athlete records or private usage counts"))
    if name.endswith("template_seed.json") and "no athlete identities" not in json.loads(text).get("source", ""):
        issues.append((name, "template provenance must declare no athlete identities"))
for name, label in issues:
    print(f"{name}: {label}")
if issues:
    raise SystemExit(1)
terms_note = f", {len(private_terms)} private terms" if private_terms else ", no private-terms file"
print(f"Repository privacy gate passed ({len(set(filter(None, paths)))} files{terms_note}).")
