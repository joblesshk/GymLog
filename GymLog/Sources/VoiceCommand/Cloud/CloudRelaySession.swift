import Foundation
import Security

/// Uses Shall We Talk's existing overseas Worker trial protocol.
/// Only installation identity is persisted. Provider keys never reach this client.
public actor CloudRelaySession {
    public static let shared = CloudRelaySession()
    public static let baseURL: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "GymLogRelayBaseURL") as? String ?? ""
        return value.isEmpty ? "https://relay.example.invalid" : value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }()
    public static var isConfigured: Bool {
        guard let url = URL(string: baseURL), let host = url.host else { return false }
        return url.scheme == "https" && !host.hasSuffix(".invalid") && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    private static func requireConfiguration() throws {
        guard isConfigured else { throw CloudVoiceError.message("請先設定自己的雲端服務地址；此版本不附帶服務或 API Key。") }
    }
    struct Grant: Decodable {
        let token: String
        let expiresAt: Double
        func usable(now: Double = Date().timeIntervalSince1970) -> Bool {
            !token.isEmpty && expiresAt.isFinite && expiresAt > now + 300
        }
    }
    private let session: URLSession
    private let credential: @Sendable () throws -> String
    public init(session: URLSession = .shared, credential: @escaping @Sendable () throws -> String = CloudRelaySession.installationCredential) {
        self.session = session; self.credential = credential
    }
    public struct Usage: Decodable, Sendable {
        public let used: Int
        public let limit: Int
        public let remaining: Int
        public let resetsAt: Double
    }
    public func usage() async throws -> Usage {
        try Self.requireConfiguration()
        var request = try Self.request(credential: credential())
        request.url = URL(string: Self.baseURL + "/v1/usage")!
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudVoiceError.message("無法讀取本月用量，請稍後重試。")
        }
        return try JSONDecoder().decode(Usage.self, from: data)
    }
    /// One operation grant, shared explicitly between its ASR and understanding stages.
    public func token() async throws -> String {
        try Self.requireConfiguration()
        let request = try Self.request(credential: credential())
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 429 {
            throw CloudVoiceError.message("本月 1,000 條雲端額度已用完，請下月再試。")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 16_384,
              let grant = try? JSONDecoder().decode(Grant.self, from: data), grant.usable() else {
            throw CloudVoiceError.message("雲端連接授權暫時不可用，請稍後重試。")
        }
        return grant.token
    }
    static func request(credential: String) throws -> URLRequest {
        guard credential.range(of: "^trial_[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw CloudVoiceError.message("無法讀取本機連接授權。")
        }
        var request = URLRequest(url: URL(string: baseURL + "/v1/trial/session")!)
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Operation-ID")
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        return request
    }
    public static func installationCredential() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.example.gymlog.cloud-relay",
            kSecAttrAccount as String: "installation-v1"]
        func read() -> String? {
            var q = query; q[kSecReturnData as String] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
            return value
        }
        if let existing = read() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CloudVoiceError.message("無法建立本機連接授權。")
        }
        let value = "trial_" + bytes.map { String(format: "%02x", $0) }.joined()
        var q = query; q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = read() { return existing }
        guard status == errSecSuccess else { throw CloudVoiceError.message("無法保存本機連接授權。") }
        return value
    }
}
