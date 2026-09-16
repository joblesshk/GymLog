import SwiftUI
import GymLogKit

/// 動作模式圖標——選動作面板與動作卡片共用（GymLog 改版設計 §3）。244 條純
/// 文字列表最缺的是視覺錨點，這裡給每個 `MovementPattern` 一個字 + 色的雙重
/// 編碼方塊，不靠顏色單獨傳達。顏色直接複用既有語意 token（accent/review/pr/
/// inferred/restored/textMid）的色值，只是換一個新用途，不新開資產。
extension MovementPattern {
    var badgeGlyph: String {
        switch self {
        case .squat: return L("蹲", "SQ")
        case .push: return L("推", "PU")
        case .pull: return L("拉", "PL")
        case .hipHinge: return L("髖", "HI")
        case .core: return L("核", "CO")
        case .carry: return L("走", "CA")
        case .conditioning: return L("能", "CD")
        case .unknown: return "?"
        }
    }

    var badgeColor: Color {
        switch self {
        case .squat: return DS.C.accent
        case .push: return DS.C.review
        case .pull: return DS.C.pr
        case .hipHinge: return DS.C.inferred
        case .core: return DS.C.restored
        case .carry, .conditioning: return DS.C.textMid
        case .unknown: return DS.C.textLow
        }
    }
}

/// 28×28、圓角 9、13% 同色底——元件規格見設計稿 §3 標注。
struct MovementPatternBadge: View {
    let pattern: MovementPattern
    var size: CGFloat = 28

    var body: some View {
        Text(pattern.badgeGlyph)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(pattern.badgeColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .background(pattern.badgeColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 「訓練體系」標籤——只在 `discipline != .strength` 時顯示（純力量動作每行
/// 都貼一次「力量」等於沒說任何事）。CrossFit 縮寫「CF」，兩者皆是縮短為
/// 「兩者」，兩者都借用 `review` 色（與模式方塊共用同一組既有 token）。
extension ExerciseDiscipline {
    var badgeLabel: String {
        switch self {
        case .strength: return displayName
        case .crossfit: return "CF"
        case .both: return L("兩者", "Both")
        }
    }

    var badgeColor: Color { DS.C.review }
}
