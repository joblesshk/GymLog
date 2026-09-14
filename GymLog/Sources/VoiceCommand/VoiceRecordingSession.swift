import AVFoundation
import Foundation
import Observation

/// Cloud-only recording. No Speech framework or on-device recognition fallback.
@MainActor @Observable
public final class VoiceRecordingSession {
    public enum Status: Equatable { case idle, recording, processing, unavailable(String) }
    public private(set) var status: Status = .idle
    public var finalTranscript: String?
    public var operationToken: String?
    public private(set) var elapsedSeconds = 0
    private let engine = AVAudioEngine()
    private var stream: VolcStreamingSession?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var installedTap = false
    private let observer = VoiceInterruptionObserver()
    public init() {
        observer.token = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelIfRecording() }
        }
    }
    public func start(locale: Locale = Locale(identifier: "zh-CN"), contextualStrings: [String] = []) {
        guard status == .idle || { if case .unavailable = status { return true }; return false }() else { return }
        let config = CloudVoiceConfiguration.load()
        guard config.hasASR else { status = .unavailable("請先在雲端設定填入語音識別服務。"); return }
        do { try config.validate() } catch { status = .unavailable("雲端設定的服務地址不正確。"); return }
        generation = UUID(); let ticket = generation; finalTranscript = nil; operationToken = nil; elapsedSeconds = 0; status = .processing
        worker = Task {
            let permitted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard ticket == generation, !Task.isCancelled else { return }
            guard permitted else { status = .unavailable("請在系統設定允許 Gym Log 使用麥克風。"); return }
            do {
                let relayToken = config.usesASRRelay ? try await CloudRelaySession.shared.token() : nil
                operationToken = relayToken
                guard ticket == generation, !Task.isCancelled else { return }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
                try session.setActive(true)
                let languageHint = "健身訓練安排與動作名稱，可使用不同語言或混合語言。"
                let hotwords: [String: Any] = ["hotwords": contextualStrings.map { ["word": $0] }, "context_data": [["text": languageHint]]]
                let hotwordText = String(data: try JSONSerialization.data(withJSONObject: hotwords), encoding: .utf8)
                let connection = VolcStreamingSession(wsURL: URL(string: config.asrURL)!, appId: config.appID,
                    accessToken: config.asrToken, resourceId: config.resourceID, hotwordsContext: hotwordText,
                    outputChineseVariant: "traditional", acceptLatestTextOnTimeout: false, bearerToken: relayToken, onPartial: { _ in })
                stream = connection
                try await connection.start()
                guard ticket == generation, !Task.isCancelled else { connection.cancel(); return }
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0,
                      let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                      let converter = AVAudioConverter(from: format, to: output) else { throw CloudVoiceError.message("麥克風格式不可用。") }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate + 32)
                    guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
                    var supplied = false; var error: NSError?
                    converter.convert(to: pcm, error: &error) { _, state in
                        if supplied { state.pointee = .noDataNow; return nil }
                        supplied = true; state.pointee = .haveData; return buffer
                    }
                    guard error == nil, pcm.frameLength > 0, let pointer = pcm.int16ChannelData?[0] else { return }
                    connection.feed(Data(bytes: pointer, count: Int(pcm.frameLength) * 2))
                }
                installedTap = true; engine.prepare(); try engine.start(); status = .recording
                timer = Task {
                    for second in 1...90 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled, ticket == generation, status == .recording else { return }
                        elapsedSeconds = second
                    }
                    stop()
                }
            } catch {
                guard ticket == generation else { return }
                releaseAudio(); stream?.cancel(); stream = nil
                status = .unavailable((error as? CloudVoiceError)?.localizedDescription ?? "雲端語音連線失敗，請檢查網絡後重試。")
            }
        }
    }
    public func stop() {
        guard status == .recording, let stream else { return }
        let ticket = generation; releaseAudio(); status = .processing
        worker = Task {
            do {
                let text = try await stream.finish()
                guard ticket == generation, !Task.isCancelled else { return }
                self.stream = nil
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = .unavailable("沒有聽到完整指令，請再說一次。"); return }
                finalTranscript = text; status = .idle
            } catch {
                guard ticket == generation else { return }
                stream.cancel(); self.stream = nil
                status = .unavailable("沒有收到完整識別結果，沒有修改訓練。請重新錄音。")
            }
        }
    }
    public func cancelIfRecording() {
        generation = UUID(); worker?.cancel(); worker = nil
        releaseAudio(); stream?.cancel(); stream = nil; finalTranscript = nil; operationToken = nil; status = .idle
    }
    private func releaseAudio() {
        timer?.cancel(); timer = nil
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private final class VoiceInterruptionObserver: @unchecked Sendable {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
