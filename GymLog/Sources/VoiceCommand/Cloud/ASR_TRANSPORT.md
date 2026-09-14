# ASR transport notes

`VolcStreamingSession.swift`, `VolcEngineASR.swift`, `TranscriptionService.swift` and `WavEncoder.swift` implement the Volcengine v3 streaming ASR protocol. They contain no credentials or app settings.

GymLog-specific behaviour: `enable_ddc` is disabled to preserve spoken corrections, and `VoiceRecordingSession` requires a final result (`acceptLatestTextOnTimeout=false`).
