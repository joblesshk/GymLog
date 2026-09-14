import Foundation
import Security

public struct CloudVoiceConfiguration: Codable, Equatable {
    public var asrURL = CloudRelaySession.baseURL.replacingOccurrences(of: "https://", with: "wss://") + "/v1/asr/bigmodel_nostream"
    public var appID = ""
    public var asrToken = ""
    public var resourceID = "volc.seedasr.sauc.duration"
    public var llmBaseURL = CloudRelaySession.baseURL + "/v1/cleanup"
    public var llmModel = "deepseek-flash"
    public var llmKey = ""
    public var hotwordLimit = 750
    public init() {}
    public var usesASRRelay: Bool { asrURL == Self().asrURL }
    public var usesLLMRelay: Bool { llmBaseURL == Self().llmBaseURL }
    public var hasASR: Bool { (usesASRRelay && CloudRelaySession.isConfigured) || (!appID.isEmpty && !asrToken.isEmpty) }
    public var hasLLM: Bool { (usesLLMRelay && CloudRelaySession.isConfigured) || (!llmKey.isEmpty && !llmModel.isEmpty) }
    public func validate() throws {
        for (text, scheme) in [(asrURL, "wss"), (llmBaseURL, "https")] {
            guard let url = URL(string: text), url.scheme == scheme, url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw CloudVoiceError.message("請使用有效的加密服務地址，不要在地址中填入密鑰。")
            }
        }
        guard (1...2000).contains(hotwordLimit) else { throw CloudVoiceError.message("熱詞數量須為 1–2000。") }
    }
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.example.gymlog.cloud-voice", kSecAttrAccount as String: "configuration-v1"]
    public static func load() -> Self {
        var q = query; q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let config = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var migrated = Self()
        migrated.hotwordLimit = config.hotwordLimit
        return migrated
    }
    public func save() throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(Self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CloudVoiceError.message("無法保存雲端設定，請重試。") }
        var q = Self.query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CloudVoiceError.message("無法保存雲端設定，請重試。") }
    }
}

public enum CloudVoiceError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

#if DEBUG
extension CloudVoiceConfiguration {
    /// Developer-device provisioning uses a one-use file in this app's sandbox, not a bundled secret.
    /// Only activated by an explicit launch argument. The transient file is always removed.
    public static func importDevelopmentConfigurationIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-importCloudVoiceSettings") else { return }
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud-voice-provision.json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Self.self, from: data) else { return }
        let receipt = file.deletingLastPathComponent().appendingPathComponent("cloud-voice-provision-result.json")
        do {
            try config.save()
            let saved = Self.load()
            let result: [String: Bool] = ["saved": saved == config, "hasASR": saved.hasASR, "hasLLM": saved.hasLLM]
            try JSONSerialization.data(withJSONObject: result).write(to: receipt, options: [.atomic, .completeFileProtection])
        } catch {
            try? Data("{\"saved\":false}".utf8).write(to: receipt, options: .atomic)
        }
    }
}
#endif
