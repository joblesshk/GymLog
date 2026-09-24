import Foundation

/// Interpret only known relay codes; never display arbitrary upstream text.
/// Older relays may return a string error, newer responses may use an object.
enum CloudRelayError {
    static func message(data: Data, response: HTTPURLResponse) -> String? {
        guard response.statusCode >= 400 else { return nil }
        let object = data.count <= 16_384 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        let error = object?["error"]
        let fields = error as? [String: Any]
        let code = (error as? String) ?? (fields?["code"] as? String) ?? (fields?["type"] as? String)
        switch code {
        case "monthly_limit":
            return L("本月雲端額度已用完，請於下月重設後再試。", "Your monthly cloud allowance is exhausted. Try again after next month's reset.")
        case "ip_rate_limit", "operation_limit":
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            if let seconds, (1...86_400).contains(seconds) {
                return L("請求過於頻繁，請於 \(seconds) 秒後重試。這不代表本月額度已用完。", "Too many requests. Retry in \(seconds) seconds. Your monthly allowance may still be available.")
            }
            return L("請求過於頻繁，請稍後重試。", "Too many requests. Please retry shortly.")
        case "service_daily_budget_exhausted":
            return L("雲端服務今日總額度已用完，請於香港時間午夜重設後再試。", "The service's daily budget is exhausted. Try again after midnight Hong Kong time.")
        case "operation_already_used_or_expired":
            return L("這次指令的授權已使用或過期，請重新提交指令。", "This operation's authorization was used or expired. Submit a new request.")
        case "quota_unavailable":
            return L("雲端額度服務暫時無法連接，請稍後重試。", "The cloud quota service is temporarily unavailable. Please retry shortly.")
        default:
            // An unrecognized 429 is not evidence of monthly exhaustion.
            if response.statusCode == 429 {
                return L("雲端服務暫時限制請求，請稍後重試或查看用量。", "Cloud requests are temporarily limited. Retry shortly or check usage.")
            }
            return nil
        }
    }
}
