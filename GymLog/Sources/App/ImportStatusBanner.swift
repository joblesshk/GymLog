import SwiftUI
import GymLogKit

struct ImportStatusBanner: View {
    enum Status: Equatable {
        case success(SeedImporter.ImportResult, elapsedSeconds: TimeInterval)
        /// M7 §3.10: a completed Excel history import. Kept as its own case
        /// (not folded into `.success`) since `SeedImporter.ImportResult`
        /// and `XLSXHistoryImporter.ImportResult` report different shapes
        /// -- client/exercise counts for a first-launch seed vs.
        /// new/existing/updated/conflict counts for an incremental import.
        case excelSuccess(XLSXHistoryImporter.ImportResult, elapsedSeconds: TimeInterval)
        case failure(String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.success, .success), (.excelSuccess, .excelSuccess), (.failure, .failure): return true
            default: return false
            }
        }
    }

    let status: Status
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        Group {
            switch status {
            case .success(let result, let elapsedSeconds):
                Label(
                    language.t(
                        "動作庫已就緒：\(result.exerciseCount) 個動作 · 用時\(String(format: "%.2f", elapsedSeconds))s",
                        "Exercise library ready: \(result.exerciseCount) exercises · \(String(format: "%.2f", elapsedSeconds))s"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(DS.C.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DS.C.accent, in: Capsule())
            case .excelSuccess(let result, let elapsedSeconds):
                Label(
                    language.t(
                        "導入完成：新增 \(result.newSessions) · 已存在 \(result.existingSessions) · 已更新 \(result.updatedSessions) · 衝突 \(result.conflictedSessions) · 用時\(String(format: "%.2f", elapsedSeconds))s",
                        "Import done: \(result.newSessions) new · \(result.existingSessions) unchanged · \(result.updatedSessions) updated · \(result.conflictedSessions) conflicts · \(String(format: "%.2f", elapsedSeconds))s"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(DS.C.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DS.C.accent, in: Capsule())
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DS.C.danger, in: Capsule())
            }
        }
        .font(.footnote)
    }
}
