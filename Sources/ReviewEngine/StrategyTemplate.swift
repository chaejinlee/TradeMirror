import Foundation

/// 选了策略之后,自动把腿摆好 —— 用户只需要填行权价。
///
/// ★ 放在引擎里而不是视图里,是因为它可以被测试。
/// 「铁鹰应该是 买P-卖P-卖C-买C」这种事,写在测试里比写在注释里管用。
public enum StrategyTemplate {

    /// 一条待填的腿。`suggestedSide` 只是默认值,用户随时可改 —— 真实方向永远由成交决定。
    public struct Draft: Sendable, Identifiable, Equatable {
        public let id = UUID()
        public var right: OptionRight?     // nil = 非期权腿(股票腿,如备兑/领口)
        public var suggestedSide: Side
        public var hint: String            // 界面上的提示,如「卖 · 平值下方」
        public init(right: OptionRight?, suggestedSide: Side, hint: String) {
            self.right = right; self.suggestedSide = suggestedSide; self.hint = hint
        }
    }

    public static func drafts(for k: StrategyKind) -> [Draft] {
        func o(_ r: OptionRight, _ s: Side, _ h: String) -> Draft { .init(right: r, suggestedSide: s, hint: h) }
        func eq(_ s: Side, _ h: String) -> Draft { .init(right: nil, suggestedSide: s, hint: h) }
        switch k {
        case .single:
            return [o(.call, .buy, "单腿")]
        case .verticalSpread:
            return [o(.call, .buy,  "买 · 近端"),
                    o(.call, .sell, "卖 · 远端")]
        case .calendarSpread:
            return [o(.call, .sell, "卖 · 近月"),
                    o(.call, .buy,  "买 · 远月(同行权价)")]
        case .diagonalSpread:
            return [o(.call, .sell, "卖 · 近月"),
                    o(.call, .buy,  "买 · 远月(不同行权价)")]
        case .straddle:
            return [o(.call, .buy, "买 Call · 平值"),
                    o(.put,  .buy, "买 Put · 同一行权价")]
        case .strangle:
            return [o(.put,  .buy, "买 Put · 下方"),
                    o(.call, .buy, "买 Call · 上方")]
        case .ironCondor:
            return [o(.put,  .buy,  "买 Put · 最下(保护)"),
                    o(.put,  .sell, "卖 Put · 下方"),
                    o(.call, .sell, "卖 Call · 上方"),
                    o(.call, .buy,  "买 Call · 最上(保护)")]
        case .ironButterfly:
            return [o(.put,  .buy,  "买 Put · 下方(保护)"),
                    o(.put,  .sell, "卖 Put · 平值"),
                    o(.call, .sell, "卖 Call · 平值(同上)"),
                    o(.call, .buy,  "买 Call · 上方(保护)")]
        case .butterfly:
            return [o(.call, .buy,  "买 · 下翼"),
                    o(.call, .sell, "卖 · 中间(×2)"),
                    o(.call, .buy,  "买 · 上翼")]
        case .coveredCall:
            return [eq(.buy, "持有正股 100 股/张"),
                    o(.call, .sell, "卖 Call · 上方")]
        case .protectivePut:
            return [eq(.buy, "持有正股"),
                    o(.put, .buy, "买 Put · 下方保护")]
        case .collar:
            return [eq(.buy, "持有正股"),
                    o(.put,  .buy,  "买 Put · 下方保护"),
                    o(.call, .sell, "卖 Call · 上方(付保护费)")]
        case .ratioSpread:
            return [o(.call, .buy,  "买 · 1 张"),
                    o(.call, .sell, "卖 · 2 张(比例腿)")]
        case .custom:
            return [o(.call, .buy, "自定义")]
        }
    }

    /// 这个策略里有没有正股腿(备兑/保护性看跌/领口有)。
    public static func hasEquityLeg(_ k: StrategyKind) -> Bool {
        drafts(for: k).contains { $0.right == nil }
    }
}
