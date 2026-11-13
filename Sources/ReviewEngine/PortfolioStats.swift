import Foundation

/// 跨笔汇总。
///
/// ★ **主角是反事实的累计,不是盈亏。**
/// 盈亏券商 App 已经告诉你了(规范开篇那句);这一页要回答的是
/// **「我那些替代做法,长期到底跑赢没有」** —— 用你自己的真实交易回测你自己的规则。
///
/// ★★ 全程受规范 [C2] 样本量纪律约束:
/// n < 10 **禁止**出现「你的胜率是」「你倾向于」这类措辞。
/// 这不是谦虚,是因为 n=5 全胜时最容易得出有害的结论(规范原话:那是有害的伪精确)。
public struct PortfolioStats: Sendable {

    /// 样本量决定这些数**能不能用来下结论**。
    public enum Confidence: String, Sendable {
        case tooFew      // n < 10:只能陈述单笔事实
        case indicative  // 10 ≤ n < 30:可以说「N 笔里有 M 笔」
        case usable      // n ≥ 30:可做分组统计,但仍须同时报样本数

        public var banner: String {
            switch self {
            case .tooFew:
                return L("样本太少,下面的数**不能用来下结论**。只能当作「N 笔里的第 M 笔」来看。")
            case .indicative:
                return L("样本仍偏少。可以说「N 笔里有 M 笔出现了 X」,**不能**说这是你的倾向。")
            case .usable:
                return L("样本量够做分组统计了,但每个结论仍须连同样本数一起看。")
            }
        }
    }

    /// 一条反事实的长期表现。
    public struct CounterfactualSummary: Sendable, Identifiable {
        public var id: String
        public var label: String
        /// 算得出这条的笔数。
        public var n: Int
        /// 其中「那样会更好」的笔数。
        public var alternativeBetter: Int
        /// 累计差额(替代 − 实际)。**正数 = 长期而言那样更好。**
        public var totalDelta: Double
        public var youWereBetter: Int { n - alternativeBetter }
    }

    /// 一条行为模式的计数。
    public struct Pattern: Sendable, Identifiable {
        public var id: String
        public var label: String
        public var hit: Int
        public var of: Int
        /// 附带的金额(例如卖早了累计少赚多少)。nil 表示这条没有金额口径。
        public var amount: Double?
    }

    public var nTotal: Int
    public var nClosed: Int
    public var nWithCounterfactuals: Int
    public var confidence: Confidence
    public var counterfactuals: [CounterfactualSummary]
    public var patterns: [Pattern]
    /// ★★ 什么**还没发生过**。规范:这通常比已发生的统计更重要
    /// (「止损 0/5 从未被触发 = 风控系统从未经检验」)。
    public var neverHappened: [String]
    public var totalPnL: Double
    public var wins: Int
    public var losses: Int
    /// 平均 MFE 捕获率(吃到峰值的百分之多少)。样本不足时为 nil。
    public var mfeCapture: Double?

    /// 一个心理状态与结果的关联。**只统计开仓前记的那些。**
    public struct StateOutcome: Sendable, Identifiable {
        public var id: String          // 状态名
        public var n: Int
        public var wins: Int
        public var totalPnL: Double
        public var isRedFlag: Bool
    }
    /// ★ 这一页唯一的主角数字:**你的做法 vs 最强的那条替代方案**。
    ///
    /// 正数 = 有一条替代做法长期比你多赚这么多(值得警惕);
    /// 负数 = 连最好的替代方案都不如你(你赢了)。
    /// nil = 还没有能算反事实的交易。
    ///
    /// 为什么只给一个数:六个 section 的统计表读不出结论,
    /// 而这一页要回答的问题只有一个 —— **我该不该改我的出场规则。**
    /// ★★ **只在可执行的方案里比。**
    /// 「若在峰值出场」被排除 —— 它是事后视角、没人卖得在最高点(规范 §3.1),
    /// 整个 App 都在警告不要拿它当依据,那它就**更不该是头条数字**。
    /// 拿一个自己说不能信的数当主角,是自己打自己脸。
    /// ★ 从枚举派生,不再手写字符串 —— 加了新的不可执行卡,这里自动跟上。
    public static let nonExecutable: Set<String> =
        Set(CFID.allCases.filter { !$0.isExecutable }.map(\.rawValue))

    public var executableAlternatives: [CounterfactualSummary] {
        counterfactuals.filter { !Self.nonExecutable.contains($0.id) }
    }
    public var vsBestAlternative: Double? {
        executableAlternatives.map(\.totalDelta).max()
    }
    /// 最强**可执行**替代方案的名字。
    public var bestAlternativeLabel: String? {
        executableAlternatives.max { $0.totalDelta < $1.totalDelta }?.label
    }

    /// 心理状态 → 结果。**只用 `beforeOutcome == true` 的记录。**
    public var stateOutcomes: [StateOutcome]
    /// 事后补记的心理标签数(单独列出,不参与任何结论)。
    public var afterTheFactPsychology: Int

    /// ★★ 「系统警告过,而你仍然做了」—— 规范说这比任何行情数据都更能预测未来的违规。
    public var warnedCount: Int
    public var proceededAnywayCount: Int
    /// 那些「警告过仍然做了」的单,合计盈亏。
    public var proceededAnywayPnL: Double

    // MARK: - 计算

    public static func compute(_ trades: [Trade], closes: DailyCloseBook = .init(),
                               basis: TimeBasis = .tradingTime) -> PortfolioStats {
        // ★ 示例交易不进统计 —— 否则用户的「历史分析」会被我编的数污染。
        let closed = trades.filter { $0.isClosed && !$0.isSample }
        let n = closed.count

        var cfAgg: [String: (label: String, n: Int, better: Int, delta: Double)] = [:]
        var captures: [Double] = []
        var withCF = 0

        for t in closed {
            let fin = t.effectiveFinalUnderlying(closes)     // ★ 当天公共收盘价兜底
            guard fin != nil || t.peakUnderlying != nil else { continue }
            withCF += 1
            let r = CounterfactualEngine.allByTime(
                trade: t, peakUnderlying: t.peakUnderlying, peakTime: t.peakTime,
                finalUnderlying: fin, basis: basis)
            for cf in r.results {
                var e = cfAgg[cf.id] ?? (cf.label, 0, 0, 0)
                e.n += 1
                if cf.verdict == .alternativeWasBetter { e.better += 1 }
                e.delta += cf.delta
                cfAgg[cf.id] = e
            }
            if let peak = r.results.first(where: { $0.id == "exit_vs_peak" }),
               let rate = CounterfactualEngine.mfeCaptureRate(exitVsPeak: peak,
                                                              costBasis: t.netDebit) {
                captures.append(rate)
            }
        }

        // ★ 排序表以前在这里抄了一份 —— 加新反事实时只改了 Counterfactuals 那份,
        //   历史页的顺序就悄悄错了(而且不会有任何报错)。现在共用 counterfactualRank。
        let cfs = cfAgg.map { k, v in
            CounterfactualSummary(id: k, label: v.label, n: v.n,
                                  alternativeBetter: v.better, totalDelta: v.delta)
        }.sorted { counterfactualRank($0.id) < counterfactualRank($1.id) }

        // ── 行为模式 ──
        let underwaterAdds = closed.filter { !$0.addsWhileUnderwater.isEmpty }.count
        let soldEarly = cfAgg["exit_vs_peak"].map { $0.better } ?? 0
        let soldEarlyOf = cfAgg["exit_vs_peak"].map { $0.n } ?? 0
        let soldEarlyAmt = cfAgg["exit_vs_peak"].map { max($0.delta, 0) }
        let weekend = closed.filter(\.hasWeekendFill).count

        var patterns: [Pattern] = [
            .init(id: "sold_before_peak", label: L("卖在峰值之前"),
                  hit: soldEarly, of: soldEarlyOf, amount: soldEarlyAmt),
            .init(id: "added_while_underwater", label: L("逆势加仓"),
                  hit: underwaterAdds, of: n, amount: nil),
        ]
        if weekend > 0 {
            patterns.append(.init(id: "weekend_fill", label: L("成交落在周末(多半是日期填错)"),
                                  hit: weekend, of: n, amount: nil))
        }

        // ── ★★ 什么还没发生过 ──
        var never: [String] = []
        if n > 0 {
            if closed.allSatisfy({ ($0.displayablePnL ?? 0) >= 0 }) {
                // ★★ 2026-09-02 自相矛盾修正:这句原来从「没有亏损单」**推断**
                //   「止损从未被检验」。而有了真实分钟路径之后我们**知道**答案 ——
                //   用户那 4 笔里有 3 笔在持仓期间**碰到过止损位**,他没按它出场。
                //   同一屏上一边说「从未被检验」、一边说「被碰到过 3 笔」= 自相矛盾。
                //   ⇒ 有证据时说事实,没证据时才说「不知道」。
                let touched = trades.filter { !$0.isSample && $0.isClosed }
                    .compactMap { $0.stopWasTouched() }
                if touched.contains(true) {
                    never.append(String(format: L("亏损 —— %1$d/%2$d 全是盈利单,但**止损位被碰到过** —— 详见下面「止损」那一栏。"), n, n))
                } else if touched.isEmpty {
                    never.append(String(format: L("亏损 —— %1$d/%2$d 全是盈利单。**止损有没有被检验过还不知道**(缺分钟路径)。"), n, n))
                } else {
                    never.append(String(format: L("亏损 —— %1$d/%2$d 全是盈利单,而且**止损位一次都没被碰到** —— 风控确实还没经检验。"), n, n))
                }
            }
            if underwaterAdds == 0 {
                never.append(L("逆势加仓 —— 0 次(这是你自述死亡模式的关键一步)"))
            }
            if !closed.contains(where: { $0.legs.count > 1 }) {
                never.append(L("多腿组合 —— 0 笔,全部是单腿"))
            }
            if !closed.contains(where: { if case .equity = $0.legs.first?.kind { return true }; return false }) {
                // ★ 原文「全部是衍生品」在他真有一笔未平仓 BEX 时是误导的。
                //   这一栏统计的是**已平仓**的交易,措辞就得说清这一点。
                never.append(L("股票/ETF 的**已平仓**记录 —— 0 笔,平掉的全是衍生品"))
            }
            let days = Set(closed.compactMap(\.tradingDayKey))
            if days.count == 1 {
                never.append(String(format: L("跨日 —— %1$d 笔全部发生在同一天(%2$@),样本无时间多样性"), n, days.first ?? ""))
            }
            if withCF < n {
                never.append(String(format: L("反事实覆盖 —— %1$d/%2$d 笔还没填收盘价。**同一天同一标的只用填一次**,填了那天全部交易都算得出来"), n - withCF, n))
            }
        }

        // ── 心理状态 × 结果:**只用开仓前记的** ──
        // 事后补的必然被结果污染(赚了选冷静、亏了选冲动),混进来会让统计变成自我印证。
        var byState: [String: (n: Int, wins: Int, pnl: Double)] = [:]
        var afterCount = 0
        for t in closed {
            guard let psy = t.psychology else { continue }
            guard psy.beforeOutcome else { afterCount += 1; continue }
            let p = t.displayablePnL ?? 0
            for st in psy.states {
                var e = byState[st] ?? (0, 0, 0)
                e.n += 1; if p > 0 { e.wins += 1 }; e.pnl += p
                byState[st] = e
            }
        }
        let states = byState.map { k, v in
            StateOutcome(id: k, n: v.n, wins: v.wins, totalPnL: v.pnl,
                         isRedFlag: Psychology.redFlags.contains(k))
        }.sorted { ($0.isRedFlag ? 0 : 1, -$0.n) < ($1.isRedFlag ? 0 : 1, -$1.n) }

        if closed.contains(where: { $0.psychology == nil }) {
            never.append(String(format: L("心理状态 —— %1$d/%2$d 笔没记(而且只有**开仓前**记的才算数)"),
                                 closed.filter { $0.psychology == nil }.count, n))
        }

        // ── ★★ 纪律:警告过 / 仍然做了 ──
        var warned = 0, proceeded = 0, proceededPnL = 0.0
        for t in closed {
            guard let snap = t.psychology?.ruleSnapshot, snap.hasWarning else { continue }
            warned += 1
            if snap.proceededAnyway {
                proceeded += 1
                proceededPnL += t.displayablePnL ?? 0
            }
        }
        if warned == 0, closed.contains(where: { $0.psychology?.ruleSnapshot != nil }) {
            never.append(L("纪律被触发 —— 0 次。**你的规则从未拦过你**,也就没被检验过"))
        }

        let conf: Confidence = n < 10 ? .tooFew : (n < 30 ? .indicative : .usable)
        return PortfolioStats(
            nTotal: trades.filter { !$0.isSample }.count, nClosed: n, nWithCounterfactuals: withCF,
            confidence: conf, counterfactuals: cfs, patterns: patterns,
            neverHappened: never,
            totalPnL: closed.reduce(0) { $0 + ($1.displayablePnL ?? 0) },
            wins: closed.filter { ($0.displayablePnL ?? 0) > 0 }.count,
            losses: closed.filter { ($0.displayablePnL ?? 0) < 0 }.count,
            mfeCapture: captures.isEmpty ? nil : captures.reduce(0, +) / Double(captures.count),
            stateOutcomes: states, afterTheFactPsychology: afterCount,
            warnedCount: warned, proceededAnywayCount: proceeded,
            proceededAnywayPnL: proceededPnL)
    }
}
