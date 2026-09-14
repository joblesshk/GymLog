# GymLog

An AI-enhanced, voice-controlled iOS workout log: say what you want to train to create or change a plan, and get AI feedback and suggestions afterwards. It also covers strength training, CrossFit WODs, athlete profiles and training history, built with SwiftUI and SwiftData. iOS 17 minimum deployment target.

This is a **source distribution**. No real athlete records, provider credentials, personal signing identity, or hosted cloud service are included. The default relay hostname is intentionally a non-routable example. Recording, history analysis and energy estimates work on the device; AI and voice features require you to configure your own API.

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

1. **Plan and log**: Set up the day's training by tapping through choices on your phone or describing it in natural language. Log what you complete as you go, and compare today's performance with past results at any time.
2. **Strength training and CrossFit WODs**: Log conventional strength training as well as CrossFit WODs, each with its own dedicated recording tools.
   - Strength work supports per-set loads and reps, supersets and drop sets, with a rest timer between sets.
   - WODs support AMRAP, For Time, EMOM and interval formats, each with a matching countdown. Phase-end alerts still arrive when the app is in the background, and the timer resumes if the app is closed and reopened.
   - Record Rx, Scaled or custom variants, and whether a workout was completed, capped or stopped.
   - Scores are only compared when the movements, quantities, loads, time limits and scoring rule match, so personal records (PRs) are not distorted by modified workouts.
   - Results produce a short summary (e.g. "AMRAP 12:00 · 5 rounds + 12 reps · Scaled") that is easy to share with a coach or teammates.
3. **Custom exercises**: Create your own exercises and choose how each is recorded (reps, time, distance or rounds) and how load is expressed (absolute weight, per side, resistance band, machine setting, assisted, and more).
4. **Coach and athlete, together**: Both sides keep their own logs and exchange training plans and past results through share files, with no manual re-entry.
5. **Import and export**: Import past training from Excel files. Export saved sessions as standard CSV, and back up or restore all data with a backup file. Select a photo of an InBody report and it is recognized and recorded on the device.
6. **Exercise library and templates**: 240 built-in bilingual exercises. Save frequently used combinations as templates to set up sessions quickly.
7. **Energy estimates**: Estimates calories burned from activity categories and the recorded training.
8. **AI feedback**: Get AI-generated reviews of your training with suggestions for improvement.

All other features work on the device; AI and voice features require you to configure your own API.

Energy estimates use population MET values and assumed timing, not direct measurement. AI reviews cannot verify exercise technique or diagnose conditions. Historical real-data regression fixtures are deliberately excluded; only the current source-distribution test results apply.

[Architecture](docs/ARCHITECTURE.md) · [Testing](docs/TESTING.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)
