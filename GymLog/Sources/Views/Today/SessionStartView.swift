import SwiftUI
import GymLogKit

/// CONTRACT-UI.md §3.5 + CONTRACT-M4.md §4.4: the idle state before a
/// session draft is open -- 新建空课次 / 复制上次同类课 / 从模板新建 (M4-A
/// addition, the seam consumer for M4-B's `SessionTemplatePickerView`,
/// CONTRACT-M4.md §5). Visual spec: HANDOFF.md §4.8.
struct SessionStartView: View {
    let client: Client
    let hasPriorSession: Bool
    /// 2026-09-09：这位学员有一节「暫時保存」了但还没「結束課次」的训练。
    /// 不摆在这里的话，教练暫存后关掉编辑，回到这一屏只看到「新建空課次」，
    /// 很容易再开一节新的、把同一堂课记成两条。
    var unfinishedSession: WorkoutSession? = nil
    var onStartEmpty: () -> Void
    var onCopyLast: () -> Void
    /// 2026-09-16：「從歷史記錄選擇」——不限最近一次，教練從完整歷史裡挑
    /// 任何一天複製（包含當天完整的區塊、動作與逐輪細節，不是只帶第一組）。
    var onCopyFromHistory: () -> Void = {}
    var onSelectTemplate: (SessionTemplate) -> Void
    var onContinueUnfinished: (WorkoutSession) -> Void = { _ in }

    @State private var showTemplatePicker = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            EmptyStateIllustration()

            VStack(spacing: 6) {
                Text(language.t("\(client.displayName) 今天還沒有開始訓練", "\(client.displayName) hasn't started training today"))
                    .font(DS.F.cardTitle)
                    .foregroundStyle(DS.C.textHi)
                    .multilineTextAlignment(.center)
                Text(language.t("選一種方式開始記錄這堂課", "Choose a way to start recording this session"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DS.C.textLow)
            }

            VStack(spacing: 10) {
                if let unfinishedSession {
                    Button {
                        onContinueUnfinished(unfinishedSession)
                    } label: {
                        Text(language.t(
                            "繼續 \(SessionDateFormat.display.string(from: unfinishedSession.date)) 未完成的課次",
                            "Continue unfinished session · \(SessionDateFormat.display.string(from: unfinishedSession.date))"
                        ))
                    }
                    .buttonStyle(.gymPrimary)

                    Button {
                        onStartEmpty()
                    } label: {
                        Text(language.t("新建空課次", "New Empty Session"))
                    }
                    .buttonStyle(.gymSecondary)
                    .accessibilityIdentifier("start-empty-session-button")
                } else {
                    Button {
                        onStartEmpty()
                    } label: {
                        Text(language.t("新建空課次", "New Empty Session"))
                    }
                    .buttonStyle(.gymPrimary)
                    .accessibilityIdentifier("start-empty-session-button")
                }

                Button {
                    onCopyLast()
                } label: {
                    Text(language.t("複製上次課次", "Copy Last Session"))
                }
                .buttonStyle(.gymSecondary)
                .disabled(!hasPriorSession)
                .opacity(hasPriorSession ? 1 : 0.4)

                Button {
                    onCopyFromHistory()
                } label: {
                    Text(language.t("從歷史記錄選擇", "Choose from History"))
                }
                .buttonStyle(.gymSecondary)
                .disabled(!hasPriorSession)
                .opacity(hasPriorSession ? 1 : 0.4)
                .accessibilityIdentifier("copy-from-history-button")

                Button {
                    showTemplatePicker = true
                } label: {
                    Text(language.t("從模板新建", "New from Template"))
                }
                .buttonStyle(.gymTertiary)
            }
            .padding(.horizontal, 32)

            if !hasPriorSession {
                Text(language.t("該學員暫無歷史課次可複製", "This client has no prior sessions to copy"))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
            }
            Spacer()
            Spacer()
        }
        .sheet(isPresented: $showTemplatePicker) {
            // 2026-09-17：Superset/WOD 模板各自有自己的分段，不該混進「從模板
            // 新建一整堂課」的清單——單獨一個 superset 或一支 WOD 處方本來就
            // 不構成一堂完整的課。
            SessionTemplatePickerView(
                onSelect: { template in
                    showTemplatePicker = false
                    onSelectTemplate(template)
                },
                filter: { !$0.isSupersetOnly && !$0.isWODOnly }
            )
        }
    }
}

/// 空状态插画（HANDOFF.md §4.8）：6 根对称圆角竖条（App 图标的线性化版本）
/// 加一根横穿的 accent 横条，不用插画素材。
///
/// 竖条颜色改用 `hairline`→`textLow`→`textMid` 三档递进（不再用 `inset`）——
/// `inset`/`hairline` 在浅色主题下都太接近 `canvas` 底色（同属"亚麻纸"色系,
/// 差值只有几档明度），插画在浅色版里几乎看不见；`textLow`/`textMid` 在浅色
/// 主题下是真正的灰褐色文字色，对 `canvas` 有足够对比度，深色主题下这三个
/// token 本来就分层清楚，一并换用不影响原有效果。
private struct EmptyStateIllustration: View {
    private let heights: [CGFloat] = [40, 58, 76, 76, 58, 40]

    private func color(for height: CGFloat) -> Color {
        switch height {
        case 76: return DS.C.textMid
        case 58: return DS.C.textLow
        default: return DS.C.hairline
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(color(for: height))
                        .frame(width: 17, height: height)
                }
            }
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DS.C.accent)
                .frame(width: 168, height: 8)
        }
        .frame(width: 168, height: 76)
    }
}
