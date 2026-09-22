import SwiftUI
import GymLogKit

/// GymLog 视觉设计系统（HANDOFF.md）。一套几何 + 两套颜色：所有颜色通过
/// Asset Catalog 的 Color Set 读取（Any/Dark Appearance 已在 .colorset 中配好），
/// 严禁硬编码 hex，否则切主题时会漏色。
///
/// 未打包 Barlow 字体文件，按 HANDOFF.md §2 的退回路径使用 `Font.system`：
/// 字号字重照规格不变，数字统一开 `.monospacedDigit()`。
enum DS {
    // MARK: Colors (§1)

    enum C {
        static let canvas = Color("canvas")
        static let surface = Color("surface")
        static let inset = Color("inset")
        static let insetSegmented = Color("insetSegmented")
        static let hairline = Color("hairline")
        static let hairlineSoft = Color("hairlineSoft")
        static let textHi = Color("textHi")
        static let textMid = Color("textMid")
        static let textLow = Color("textLow")
        static let accent = Color("accent")
        static let onAccent = Color("onAccent")
        static let accentSoft = Color("accentSoft")
        static let inferred = Color("inferred")
        static let inferredBg = Color("inferredBg")
        static let review = Color("review")
        static let reviewBg = Color("reviewBg")
        static let restored = Color("restored")
        static let restoredBg = Color("restoredBg")
        static let pr = Color("pr")
        static let prBg = Color("prBg")
        static let danger = Color("danger")
        static let chevron = Color("chevron")
    }

    // MARK: Typography (§2)

    enum F {
        /// 页面标题（今天 / 历史 / 动作库 / 设置）：30 / Heavy
        static let pageTitle = Font.system(size: 30, weight: .heavy)
        /// 导航标题（课次日期）：18 / Bold
        static let navTitle = Font.system(size: 18, weight: .bold)
        /// 卡片标题（动作名）：17 / Bold
        static let cardTitle = Font.system(size: 17, weight: .bold)
        /// 列表主行（动作名、设置项）：15 / SemiBold
        static let listRow = Font.system(size: 15, weight: .semibold)
        /// 正文（目标/完成、热身内容）：14 / Medium
        static let body = Font.system(size: 14, weight: .medium)
        /// 副标题：11 / Regular
        static let subtitle = Font.system(size: 11, weight: .regular)
        /// 分组标签 / 表头：10 / SemiBold，字距 +0.14em，全大写（英文）
        static let sectionLabel = Font.system(size: 10, weight: .semibold)
        /// 数据标签（推断 / 待复核 / 日期已还原）：10 / SemiBold
        static let dataLabel = Font.system(size: 10, weight: .semibold)
        /// Round 表头缩写（R1/R2）：12 / textMid
        static let roundTag = Font.system(size: 12, weight: .regular)
        /// 数据数字（重量/组数/次数）：19 / SemiBold + 等宽数字
        static func dataNumber() -> Font { .system(size: 19, weight: .semibold) }
        /// 数字单位：11 / textLow
        static let dataUnit = Font.system(size: 11, weight: .regular)
        /// CONTRACT-M9.md v2: Round 表格单行五列（组数/重量/目标/实际 + 可选删除）
        /// 挤压后单元格用的缩小版数字/单位/Round 标签，与 `dataNumber()`/
        /// `dataUnit`/`roundTag` 同角色但更小 -- 5 列共享一行宽度時常规尺寸放
        /// 不下，尤其是"重量"格偶尔出现的较长文本（"輔助 30kg"）。
        static func dataNumberCompact() -> Font { .system(size: 15, weight: .semibold) }
        static let dataUnitCompact = Font.system(size: 9, weight: .regular)
        static let roundTagCompact = Font.system(size: 11, weight: .semibold)
        /// 计时器（1:00）：26 / SemiBold + 等宽数字
        static func timer() -> Font { .system(size: 26, weight: .semibold) }
        /// 时长数值（60）：22 / SemiBold + 等宽数字
        static func durationValue() -> Font { .system(size: 22, weight: .semibold) }
        /// 时长单位（分钟）：12 / textLow
        static let durationUnit = Font.system(size: 12, weight: .regular)
    }

    /// 字距 +0.14em，用于分组标签 / 表头
    static let sectionTracking: CGFloat = 1.4

    // MARK: Spacing / Radius / Sizing (§3)

    enum Space {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s14: CGFloat = 14
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        /// 页边距
        static let pageMargin: CGFloat = 16
        /// 卡片间距
        static let cardGap: CGFloat = 10
        /// 卡片内边距
        static let cardPadding: CGFloat = 14
    }

    enum Radius {
        /// 卡片
        static let card: CGFloat = 16
        /// 输入框 / 分段控件 / 主按钮
        static let control: CGFloat = 14
        /// 步进器
        static let stepper: CGFloat = 12
        /// 数据标签
        static let dataTag: CGFloat = 6
        /// 全圆（Round 药丸、学员切换器）
        static let pill: CGFloat = 999
    }

    enum Size {
        /// Round 表格行高
        static let roundRow: CGFloat = 38
        /// 课次详情组行高
        static let detailRow: CGFloat = 38
        /// 列表行高
        static let listRow: CGFloat = 44
        /// 最小命中区域
        static let minHit: CGFloat = 44
        /// 主按钮 / 次按钮 / 三级按钮高度
        static let buttonHeight: CGFloat = 50
        /// 步进器格
        static let stepperCell: CGFloat = 34
    }
}

// MARK: - Reusable modifiers

private struct MinHitTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: DS.Size.minHit, minHeight: DS.Size.minHit)
    }
}

extension View {
    /// 保证可点元素命中区域 ≥ 44×44（§3）。
    func minHitTarget() -> some View {
        modifier(MinHitTarget())
    }

    /// 分组标签 / 表头文字样式：10pt SemiBold，字距 +0.14em，`textLow`。
    func sectionLabelStyle() -> some View {
        self
            .font(DS.F.sectionLabel)
            .tracking(DS.sectionTracking)
            .foregroundStyle(DS.C.textLow)
    }
}

// MARK: - Data tags (§4.4): 推断 / 待复核 / 日期已还原

enum DataTagKind {
    case inferred
    case review
    case restored
    case pr
    /// 2026-09-10：`WODPRAnalyzer` 分组内的第一条有效成绩——是比较的起点/
    /// 基准，还没有真正"破紀錄"，不该和 `.pr` 用同一个金色标签混为一谈
    /// （反馈原文：首次有效成绩显示"首次成绩／基准"，后续真正改善才显示"新
    /// 纪录"）。沿用 `inferred` 的中性配色，不新开 colorset。
    case baseline
    /// 2026-09-09：已「暫時保存」但还没「結束課次」的课次。沿用 accent 一对
    /// 颜色，不新开 colorset——它是一个临时状态标记，不是新的数据来源类别。
    case inProgress

    var label: String {
        switch self {
        case .inferred: return L("推斷", "Inferred")
        case .review: return L("待復核", "Needs Review")
        case .restored: return L("日期已還原", "Date Restored")
        case .pr: return L("PR", "PR")
        case .baseline: return L("首次成績", "Baseline")
        case .inProgress: return L("進行中", "In Progress")
        }
    }

    var fg: Color {
        switch self {
        case .inferred: return DS.C.inferred
        case .review: return DS.C.review
        case .restored: return DS.C.restored
        case .pr: return DS.C.pr
        case .baseline: return DS.C.inferred
        case .inProgress: return DS.C.accent
        }
    }

    var bg: Color {
        switch self {
        case .inferred: return DS.C.inferredBg
        case .review: return DS.C.reviewBg
        case .restored: return DS.C.restoredBg
        case .pr: return DS.C.prBg
        case .baseline: return DS.C.inferredBg
        case .inProgress: return DS.C.accentSoft
        }
    }
}

struct DataTagView: View {
    let kind: DataTagKind

    var body: some View {
        Text(kind.label)
            .font(DS.F.dataLabel)
            .foregroundStyle(kind.fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(kind.bg, in: RoundedRectangle(cornerRadius: DS.Radius.dataTag, style: .continuous))
    }
}

// MARK: - Buttons (§4.6)

struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(DS.C.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Size.buttonHeight)
            .background(
                (isEnabled ? DS.C.accent : DS.C.accent.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DS.C.textHi)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Size.buttonHeight)
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(DS.C.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct TertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DS.C.textMid)
            .frame(maxWidth: .infinity)
            .frame(height: DS.Size.buttonHeight)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 「往这堂课里加内容」的按钮（添加動作 / 添加 WOD）。2026-09-09 教练反馈：
/// 「Save Draft 和 Finish Session 放在了 Add Exercise 和 Add WOD 下面，按钮都
/// 一样大，给人非常同质化的感觉」——这两组按钮做的是完全不同的事，一组往课
/// 次里加东西、一组结束并保存整堂课，长得一样就只能靠读字来分辨。
///
/// 所以这一档在视觉上刻意与 primary/secondary 拉开：虚线描边（"这里还可以再
/// 放东西"的通用语汇）、accent 色文字、矮一档的高度、没有实心底色。它永远不会
/// 被误看成一个"提交"按钮。
struct AddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.C.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(DS.C.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.C.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == AddButtonStyle {
    static var gymAdd: AddButtonStyle { AddButtonStyle() }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var gymPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var gymSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == TertiaryButtonStyle {
    static var gymTertiary: TertiaryButtonStyle { TertiaryButtonStyle() }
}

// MARK: - Segmented control (§4.7)

/// 分段控件：外层 `insetSegmented` 圆角 12、padding 3；选中项圆角 9，深色 =
/// `accentSoft` 底 + `accent` 文字，浅色 = `surface` 底 + `accent` 文字；
/// 未选中 13/SemiBold `textMid`。
struct GymSegmentedControl<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    @Environment(\.colorScheme) private var colorScheme

    init(selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        _selection = selection
        self.options = options
        self.label = label
    }

    private var selectedBackground: Color {
        colorScheme == .dark ? DS.C.accentSoft : DS.C.surface
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? DS.C.accent : DS.C.textMid)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? selectedBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.C.insetSegmented, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Card container (§4.3 / general surface card)

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = DS.Radius.card

    func body(content: Content) -> some View {
        content
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func gymCard(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}
