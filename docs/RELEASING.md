# Release process

1. Use the intended reviewed checkout and preserve unrelated local changes. Run repository privacy checks, synthetic tests and app build. Recheck third-party licenses and changed data flows.
2. Keep local API URL, bundle identifiers and Apple signing team in the ignored `GymLog/Config/Local.xcconfig`; shared `Build.xcconfig` supplies safe defaults. Preserve this local file when exporting/pushing to GitHub; exclude it from the export rather than deleting it. Do not commit signing identities, certificates, provisioning profiles or App Store Connect API keys.
3. Increment `CURRENT_PROJECT_VERSION` in `GymLog/project.yml`, then regenerate the project. The app and embedded framework inherit the same build number.
4. Build/archive into a directory outside the repository. Use an Xcode/SDK combination currently accepted by Apple; a local successful archive is not proof of App Store acceptance.
5. Verify the signed artifact using `codesign --verify --deep --strict`, check app/framework versions and review permission descriptions. `scripts/check-release-privacy.py` checks binary Speech linkage and microphone purpose text for the current cloud-voice design.
6. Install on a device with your own identity and verify installed version and launch. If updating an existing installation, back up the data and test migration before distribution.
7. Export/upload through your own Xcode account. Verify upload and subsequent processing separately; do not claim TestFlight availability from an upload receipt alone.
8. Create a Git tag and GitHub release only after the relevant checks. Use synthetic screenshots and exclude databases, logs with device/account metadata, and credentials from attachments.

The CI workflow builds and tests only. It never signs, installs, uploads to Apple, deploys a Worker or accesses production secrets automatically.
