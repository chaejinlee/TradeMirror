import Foundation

/// 用户自己的硬规则。默认值来自规范 `profile.hard_rules`。
///
/// ★ 只放**开仓那一刻能自动判定**的规则。
/// 「单标的 ≤ 50%」这类需要持仓总览的,做不到自动判就不放 ——
/// 放一条判不了的规则,它就永远显示「通过」,比不放更糟。
public struct TradingRules: Codable, Sendable, Equatable {
    public var minConfidence: Int
    public var maxConsecutiveLosses: Int
    public var dailyLossLimitPct: Double
    public var coolDownMinutesAfterLoss: Int
    /// 净值。没填的话「日亏 X%」这条判不了,会显示「缺净值,判不了」而不是「通过」。
    public var equity: Double?
    /// 移动止损的回撤百分比。**用来算「若用移动止损会怎样」这条反事实。**
    /// ★ 为什么做成可配:挑一个事后看最好的参数是数据挖掘。
    ///   固定成**你自己声明过的那个数**,这条反事实才有意义。
    public var trailingStopPct: Double = 25

    public var enabled: Bool

    public init(minConfidence: Int = 4, maxConsecutiveLosses: Int = 3,
                dailyLossLimitPct: Double = 3, coolDownMinutesAfterLoss: Int = 15,
                equity: Double? = nil, enabled: Bool = true) {
        self.minConfidence = minConfidence
        self.maxConsecutiveLosses = maxConsecutiveLosses
        self.dailyLossLimitPct = dailyLossLimitPct
        self.coolDownMinutesAfterLoss = coolDownMinutesAfterLoss
        self.equity = equity; self.enabled = enabled
    }

    // ★★ 手写 `init(from:)`,不能用合成的。
    //
    //   2026-09-01 实测踩到:给这个结构体加了 `trailingStopPct` 之后,
    //   **所有旧存档整份读不出来** —— Swift 合成的解码对「非可选字段缺 key」直接抛错,
    //   属性上的默认值它不看。用户会看到「数据文件读不出来」。
    //   (幸好 `TradeStore` 的坏文件留档兜住了,没有静默清空 —— 那正是它存在的理由。)
    //
    //   ⇒ 规则:**这个仓库里凡是会被存档的结构体,新增字段一律走 `decodeIfPresent` + 默认值。**
    //     `Trade` 和 `StoreFile` 早就这么做了,加字段时我忘了这条也适用于 `TradingRules`。
    private enum CodingKeys: String, CodingKey {
        case minConfidence, maxConsecutiveLosses, dailyLossLimitPct
        case coolDownMinutesAfterLoss, equity, trailingStopPct, enabled
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let dflt = TradingRules()
        minConfidence = try c.decodeIfPresent(Int.self, forKey: .minConfidence) ?? dflt.minConfidence
        maxConsecutiveLosses = try c.decodeIfPresent(Int.self, forKey: .maxConsecutiveLosses)
            ?? dflt.maxConsecutiveLosses
        dailyLossLimitPct = try c.decodeIfPresent(Double.self, forKey: .dailyLossLimitPct)
            ?? dflt.dailyLossLimitPct
        coolDownMinutesAfterLoss = try c.decodeIfPresent(Int.self, forKey: .coolDownMinutesAfterLoss)
            ?? dflt.coolDownMinutesAfterLoss
        equity = try c.decodeIfPresent(Double.self, forKey: .equity)
        trailingStopPct = try c.decodeIfPresent(Double.self, forKey: .trailingStopPct)
            ?? dflt.trailingStopPct
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? dflt.enabled
    }
}

/// 一条规则的判定结果。
public struct RuleVerdict: Codable, Sendable, Equatable, Identifiable {
    public enum Level: String, Codable, Sendable { case pass, warn, blocked, unknown }
    public var id: String
    /// ★★ 这里存的是**格式 key**(中文原文,带 `%@`),不是拼好的句子。
    ///   以前存拼好的中文,进 `Text(String)` 后**永远不本地化** ——
    ///   规范 §2.3 要求这份判定「一旦写下就不再重算」,
    ///   所以正确做法是<b>冻结数字、显示时才翻</b>,而不是冻结中文。
    ///   老存档里存的是拼好的句子(没有 `%`),`String(format:)` 原样返回,兼容。
    public var label: String
    public var labelArgs: [String]
    public var level: Level
    /// 判定依据的具体数字,让用户能核对(而不是只看到一个红叉)。
    public var detail: String
    public var detailArgs: [String]

    public init(id: String, label: String, labelArgs: [String] = [],
                level: Level, detail: String, detailArgs: [String] = []) {
        self.id = id; self.label = label; self.labelArgs = labelArgs
        self.level = level; self.detail = detail; self.detailArgs = detailArgs
    }

    // ★ 老存档没有 args 两个字段。合成的 Codable 遇到缺字段会**抛**,
    //   那会让整份存档读不出来(2026-08 加 trailingStopPct 时已经栽过一次)。
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        level = try c.decode(Level.self, forKey: .level)
        detail = try c.decode(String.self, forKey: .detail)
        labelArgs = try c.decodeIfPresent([String].self, forKey: .labelArgs) ?? []
        detailArgs = try c.decodeIfPresent([String].self, forKey: .detailArgs) ?? []
    }

    /// 显示用的成句。★ 翻译走 `EngineL10n` 钩子:
    ///   App 里接了 `Loc.t` ⇒ 出译文;测试里是恒等 ⇒ 出中文原文。
    public var labelText: String { Self.fill(label, labelArgs) }
    public var detailText: String { Self.fill(detail, detailArgs) }

    static func fill(_ key: String, _ args: [String]) -> String {
        args.isEmpty ? L(key) : String(format: L(key), arguments: args as [CVarArg])
    }
}

/// ★ 开仓那一刻的**冻结快照**。
///
/// 规范 §2.3 原话:「**绝对不要事后重算这一块。**
/// 事后重算带幸存者偏差,而且丢失了『系统警告过、用户仍然做了』这条**行为**记录
/// —— 这比任何行情数据都更能预测未来的违规。」
///
/// 所以这个结构一旦写下就不再重算,`proceededAnyway` 是它存在的全部理由。
public struct RuleSnapshot: Codable, Sendable, Equatable {
    public var checkedAt: Date
    public var verdicts: [RuleVerdict]
    /// 系统警告过,而用户**仍然开了这一单**。
    public var proceededAnyway: Bool

    public var warnings: [RuleVerdict] { verdicts.filter { $0.level == .warn || $0.level == .blocked } }
    public var hasWarning: Bool { !warnings.isEmpty }

    public init(checkedAt: Date = Date(), verdicts: [RuleVerdict], proceededAnyway: Bool) {
        self.checkedAt = checkedAt; self.verdicts = verdicts
        self.proceededAnyway = proceededAnyway
    }
}

public enum RuleEngine {

    /// 开仓那一刻的上下文。全部从已有数据算出来,不用用户再填。
    public struct Context: Sendable {
        public var confidence: Int
        public var now: Date
        public var closedToday: [Trade]
        public var allClosed: [Trade]
        public init(confidence: Int, now: Date = Date(),
                    closedToday: [Trade], allClosed: [Trade]) {
            self.confidence = confidence; self.now = now
            self.closedToday = closedToday; self.allClosed = allClosed
        }
    }

    /// **不依赖「这一单」**的上下文 —— 今天的状态本身就能判。
    public struct StandingContext: Sendable {
        public var now: Date
        public var closedToday: [Trade]
        public init(now: Date = Date(), closedToday: [Trade]) {
            self.now = now; self.closedToday = closedToday
        }
    }

    /// 开仓那一刻的全套判定 = **信心度 + 常驻那几条**。
    ///
    /// ★ 两个入口共用同一份实现 —— 规则只能有一处定义。
    ///   这个项目在「同一件事写两遍」上栽过(周起点、counterfactualRank)。
    public static func check(_ r: TradingRules, _ c: Context) -> [RuleVerdict] {
        guard r.enabled else { return [] }
        // ① 信心度:**只有开仓那一刻有意义** —— 主页那条常驻的判不了它
        var out: [RuleVerdict] = [.init(
            id: "confidence", label: "信心度 ≥ %@ 才开单",
            labelArgs: ["\(r.minConfidence)"],
            level: c.confidence >= r.minConfidence ? .pass : .warn,
            detail: "这一单信心度 %@", detailArgs: ["\(c.confidence)"])]
        out += standing(r, .init(now: c.now, closedToday: c.closedToday))
        return out
    }

    /// 常驻判定:**今天的状态**。给主页那条横幅用。
    ///
    /// ★★ 2026-09-22 复盘查出来的洞:`check` 全项目<b>只有一个调用点</b> ——
    ///   「开仓前」那一屏。而用户 23 笔已平仓里只有 6 笔填过心理状态,
    ///   <b>也就是说这个熔断器四次里最多被问到一次</b>。
    ///   09-04 亏 $893、09-08 亏 $796 —— 正是日亏上限存在的理由,
    ///   <b>而它当时根本没有机会说话</b>。
    ///   ⇒ 把和「这一单」无关的那几条拆出来,挂在主页上常驻。
    public static func standing(_ r: TradingRules, _ c: StandingContext) -> [RuleVerdict] {
        guard r.enabled else { return [] }
        var out: [RuleVerdict] = []

        // ② 连亏 N 笔当日停
        let losses = consecutiveLosses(c.closedToday)
        out.append(.init(
            id: "consecutive_losses", label: "连亏 %@ 笔当日停",
            labelArgs: ["\(r.maxConsecutiveLosses)"],
            level: losses >= r.maxConsecutiveLosses ? .blocked : .pass,
            detail: "今天已连亏 %@ 笔", detailArgs: ["\(losses)"]))

        // ③ 日亏上限
        let dayPnL = c.closedToday.reduce(0.0) { $0 + ($1.displayablePnL ?? 0) }
        if let eq = r.equity, eq > 0 {
            let limit = -eq * r.dailyLossLimitPct / 100
            out.append(.init(
                id: "daily_loss", label: "日亏 %@ 当日停",
                labelArgs: ["\(r.dailyLossLimitPct.cleanNum)%"],
                level: dayPnL <= limit ? .blocked : .pass,
                detail: "今日 %1$@ / 上限 %2$@",
                detailArgs: [dayPnL.usdShort, limit.usdShort]))
        } else {
            out.append(.init(
                id: "daily_loss", label: "日亏 %@ 当日停",
                labelArgs: ["\(r.dailyLossLimitPct.cleanNum)%"],
                level: .unknown,
                detail: "没填净值,这条判不了"))   // ★ 判不了就说判不了,不许显示「通过」
        }

        // ④ 亏损后冷静期
        if let last = lastLoss(c.closedToday) {
            let mins = Int(c.now.timeIntervalSince(last) / 60)
            out.append(.init(
                id: "cooldown", label: "亏损后 %@ 分钟内不开新仓",
                labelArgs: ["\(r.coolDownMinutesAfterLoss)"],
                level: mins < r.coolDownMinutesAfterLoss ? .blocked : .pass,
                detail: "距上一笔亏损 %@ 分钟", detailArgs: ["\(mins)"]))
        } else {
            out.append(.init(
                id: "cooldown", label: "亏损后 %@ 分钟内不开新仓",
                labelArgs: ["\(r.coolDownMinutesAfterLoss)"],
                level: .pass, detail: "今天还没有亏损单"))
        }
        return out
    }

    /// 主页那条横幅要不要出现、长什么样。
    ///
    /// ★ 全过就**不出声** —— 常驻的绿色提示等于没有提示。
    ///   只在 `blocked` / `warn` 时挂出来。
    public struct StandingStatus: Sendable, Equatable {
        public var worst: RuleVerdict.Level
        public var hits: [RuleVerdict]
        /// 该不该在主页上挂。
        public var shouldShow: Bool { worst == .blocked || worst == .warn }
        /// 规则没开、或者一条都判不了。
        public var isSilent: Bool { hits.isEmpty && worst == .pass }
    }

    public static func status(_ r: TradingRules, _ c: StandingContext) -> StandingStatus {
        let v = standing(r, c)
        let hits = v.filter { $0.level == .blocked || $0.level == .warn }
        let worst: RuleVerdict.Level =
            hits.contains { $0.level == .blocked } ? .blocked
            : (hits.isEmpty ? .pass : .warn)
        return StandingStatus(worst: worst, hits: hits)
    }

    /// 今天末尾的连续亏损笔数(按出场时间排序)。
    static func consecutiveLosses(_ today: [Trade]) -> Int {
        let sorted = today.sorted { ($0.fills.map(\.time).max() ?? .distantPast)
                                  < ($1.fills.map(\.time).max() ?? .distantPast) }
        var n = 0
        for t in sorted.reversed() {
            guard let p = t.displayablePnL else { break }
            if p < 0 { n += 1 } else { break }
        }
        return n
    }

    static func lastLoss(_ today: [Trade]) -> Date? {
        today.filter { ($0.displayablePnL ?? 0) < 0 }
             .compactMap { $0.fills.map(\.time).max() }
             .max()
    }
}

extension Double {
    var usdShort: String { String(format: self < 0 ? "−$%.0f" : "$%.0f", abs(self)) }
}
