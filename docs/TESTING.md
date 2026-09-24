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

## Review regressions

`ReviewRegressionTests`, `ImportedSessionEditRoundTripTests` and `CloudVoiceTests` cover unchanged-field preservation across reopening, quick/full editing, snapshot restore, set splitting, voice resizing and copying a new session. Exchange validation tests reject duplicate IDs at both parse and direct commit boundaries without rolling back unrelated pending edits.

Backend route tests use the production QuotaDO handler with serialized in-memory storage; concurrency, denied budgets, replay and unavailable-budget retries are tested without providers. `promptConfig.test.ts` links deployment hashes to `CloudPromptPinTests`, which separately verifies the actual Swift prompt bytes. Wrangler local runtime validation is separate from the mock-storage tests and does not prove production connectivity.

### Flexible load editor

- `LoadSelectionDraftTests`: band-to-pound entry beyond preset bounds, unit/value Codable round-trip, canonical-kg volume, preservation of original representations, custom bands/descriptions, validation, explicit added load versus inferred assistance, and transactional history overrides with unknown actuals.
- `CustomLoadWeightUITests`: manual numeric presets, two-wheel kg/lb selection for band chin-ups, reopening and cancellation, switching back to a custom band color, and unchanged actual-result confirmation.

- `BandLoadCoverageTests` enumerates every bundled band exercise and checks numeric kg/lb overrides, historical band loads under every equipment classification, composite/light color localization, and preservation of unknown custom models. Chinese/English UI cases verify saved labels, reopened fields, wheel labels and the compact Band / Weight switch. The bodyweight case verifies the numeric wheel can select additional weight and return to Bodyweight without a full type menu.

### Current device build: 1.0 (38)

The six compact-load UI cases passed for build 36. The final visual refinements were checked again with two existing language/theme cases for build 38: English in dark mode and Traditional Chinese in light mode, covering band editing, reopening, numeric switching and saving. Both passed; exported screenshots were visually inspected. Build 38 also passed Release compilation, signing and release privacy checks, and was installed and launched on the device. Eleven business-table digests matched before and after installation, before first launch. This is installation evidence, not user acceptance of readability on the device.
