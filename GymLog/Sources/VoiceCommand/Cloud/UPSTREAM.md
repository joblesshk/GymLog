# Shall We Talk ASR reuse

Source snapshot: 2026-09-14. Copied protocol/transport only; no credentials or app settings. Upstream app is unchanged.

- VolcStreamingSession.swift: SHA256 680d8e4e577a6d3c2c55c4c5adb511617bb001f49d711d29f597786d2d0fd560
- VolcEngineASR.swift: SHA256 540c59000d450cbb9c253f182901d2893a0f85b8402410c4973616245633a7ab
- TranscriptionService.swift: SHA256 a3dc5e18157efe3b0f37bf1c6aa979f53b5b07a4712848ed97eb43c93df6639f
- WavEncoder.swift: SHA256 a2828abe03a31b61f021b291010649c01fead7787aa39b1d541f0fcf7b32c809

Gym Log adaptations: disabled enable_ddc to preserve spoken corrections; removed the two optional CoreDiagLog callbacks. VoiceRecordingSession requires a final result (acceptLatestTextOnTimeout=false). Remaining protocol transport is the copied snapshot.
