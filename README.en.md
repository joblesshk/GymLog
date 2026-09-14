# GymLog

An iOS workout log built with SwiftUI and SwiftData. Supports strength sessions, supersets, CrossFit WODs, athlete profiles, training history, local energy estimates, and optional cloud voice / AI reviews. iOS 17 minimum deployment target.

This is a **source distribution**. No real athlete records, provider credentials, personal signing identity, or hosted cloud service are included. The default relay hostname is intentionally a non-routable example. Recording and local analytics work without a cloud account.

## Build

Install Xcode and XcodeGen on macOS, then run from the repository root:

```sh
brew install xcodegen
(cd GymLog && xcodegen generate)
xcodebuild -project GymLog/GymLog.xcodeproj -scheme GymLog \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
bash scripts/test-ios.sh
```

Device builds require your own Apple team and unique bundle identifiers. Cloud voice and training reviews require a separately deployed relay with provider secrets stored server-side. See [setup](docs/SETUP.md) and [relay deployment](backend/worker-relay/README.md).

## Features and limits

- Planned and recorded quantities, loads, rounds, supersets, timers and unit-aware history.
- AMRAP / For Time / EMOM / interval prescriptions and results.
- Profiles, body metrics, local spreadsheet/OCR import, backups, CSV and session exchange.
- 240 bilingual exercise entries and synthetic demonstration templates.
- Estimated activity energy and optional DeepSeek reviews; missing data stays missing.

Energy estimates use population MET values and assumed timing, not direct measurement. AI reviews cannot verify exercise technique or diagnose conditions. Historical real-data regression fixtures are deliberately excluded; only the current source-distribution test results apply.

[Architecture](docs/ARCHITECTURE.md) · [Testing](docs/TESTING.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)
