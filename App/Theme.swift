import SwiftUI

/// **全 App 唯一的视觉定义。**
///
/// ★★ 2026-09-24 用户:「想办法美化一下我们的复盘软件」。
///   查下来最大的问题不是哪一屏丑,而是**根本没有一套主题** ——
///   71 处硬编码的 `Color.red/green`、56 处橙色,每屏各选各的。
///   而 App 图标早就定下了一套视觉语言,<b>App 本身却完全没用它</b>:
///
///     底    #0C0C18  深海军蓝
///     绿    #30CC78  你走的那条路(实线)
///     琥珀  #FC9C48  你没走的那条路(虚线)
///     白    #F0F0FC  决策点
///
///   这正是复盘页「实线是你,虚线是你没走的」那个比喻。
///   ⇒ 颜色从图标里取,**只在这一个文件里定义**。
///
/// ★ 红绿对色弱(deutan)天然分不开 —— dataviz 校验器实测纯红绿只有 ΔE≈3。
///   但交易软件里红绿是改不了的约定(他券商也是绿涨红跌)。
///   这里的补救是:<b>每个盈亏数字都带 `+`/`−` 号</b>(规范里说的「第二编码」),
///   所以颜色只负责「一眼扫过去」,不负责「唯一能分辨的依据」。
enum Theme {

    // MARK: - 颜色

    /// 赚。图标的绿:浅色下压暗一档保证文字对比度,深色下用图标原色。
    static let profit = dynamic(light: 0x148A50, dark: 0x3DD68C)
    /// 亏。
    static let loss   = dynamic(light: 0xE0454A, dark: 0xFF6B6F)
    /// **你没走的那条路** —— 反事实、替代做法。图标的琥珀。
    static let alt    = dynamic(light: 0xC96A12, dark: 0xFFA94D)
    /// 需要留神的事(提醒、缺字段)。★ 永远和图标一起出现,不单靠颜色。
    static let warn   = Color.orange
    /// 还没平的仓位 —— 不是警告,是「进行中」。
    static let open   = dynamic(light: 0xB7791F, dark: 0xE0A458)

    /// 买 / 卖(方向,不是盈亏)。
    /// ★★ 2026-09-24:原来四处各用各的 —— K 线图「卖」是紫色,成交列表、逐腿明细、
    ///   批量确认页的「卖」是**橙色**,而橙色同时是警告色,「卖」看起来像在报错。
    ///   ⇒ 统一成 K 线图那套。紫色和盈亏的红绿、反事实的琥珀、警告的橙都不撞。
    static let buy  = Color.blue
    static let sell = Color.purple

    /// 赚/亏/持平,一处说了算。
    static func pnl(_ v: Double) -> Color { v > 0 ? profit : (v < 0 ? loss : .secondary) }

    /// 卡片底色。★ 和 List 自己的分组卡片**同一个颜色** ——
    ///   第一版在深色下给了一点海军蓝,结果头卡和下面几张系统卡片并排时颜色对不上,
    ///   看起来像 bug。<b>一致比有个性重要。</b>(整页换成海军蓝底是另一件事,要全屏一起换。)
    static let card   = Color(.secondarySystemGroupedBackground)
    /// 页面底色。
    static let page   = dynamic(light: 0xF4F4F7, dark: 0x0E0F16)
    /// 热力图里「那天没交易」的空格 —— 要**退到背景里**,不能和有交易的格子抢。
    static let emptyCell = dynamic(light: 0xECECF0, dark: 0x22242F)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    // MARK: - 尺寸

    static let radius: CGFloat = 16
    static let pad: CGFloat = 16
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 卡片:圆角 + 卡片底色。★ 全 App 的卡片都长这样。
struct CardStyle: ViewModifier {
    var padding: CGFloat = Theme.pad
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = Theme.pad) -> some View { modifier(CardStyle(padding: padding)) }
}

/// 小标签(`逆势加仓`、`股票/ETF`、`713C`)。
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// 可开关的标签(开仓前的状态、以后别处的多选)。
struct ChipToggle: View {
    let label: LocalizedStringKey
    let on: Bool
    var tint: Color = .accentColor
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(label).font(.subheadline)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? tint : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: on)
    }
}

/// 从左往右排、排满换行。★ SwiftUI 自带的没有这个,iOS 16 起可以自己写 `Layout`。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
