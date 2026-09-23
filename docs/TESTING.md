# Testing

From the repository root:

```sh
python3 scripts/check-repository.py
bash scripts/test-ios.sh
(cd backend/worker-relay && npm ci --ignore-scripts && npm run check)
```

The iOS script generates the project, selects an available iPhone simulator, runs GymLogKitTests and builds the app. Set `GYMLOG_SIMULATOR_ID` and optionally `GYMLOG_DERIVED_DATA` to control the destination. No Apple signing credentials are required for simulator checks.

UI tests use an isolated in-memory profile through `-uiTesting`. Run the GymLogUITests scheme on a simulator; do not use this launch argument as a way to test personal data preservation on a real phone.

Tests must use synthetic fixture data or mocked network transport. Historical workbooks, original body-report OCR dumps, private photos and derived real-history regression suites have been excluded from this source release. Do not cite the earlier private test totals as this repository's coverage.

The repository gate checks paths, fixture provenance, sync-conflict duplicates and common secret/signing/team-ID patterns without printing matched values. Keep client names, real bundle identifiers and team IDs one per line in `~/.config/gymlog/private-terms.txt` (or the file named by `GYMLOG_PRIVATE_TERMS`); the gate then rejects any tracked file containing them. That file must never be committed. Run Gitleaks on the commit history before publishing:

```sh
gitleaks git . --redact=100
```

No scanner proves that all personal information is absent. Review data provenance and staged file content, particularly new media, fixtures and logs. Gitignore does not remove an already tracked file or rewrite old history.

Passing tests do not establish individualized energy accuracy, professional coaching quality, BLE device compatibility or sustained real-device behavior. These require separate acceptance evidence.
