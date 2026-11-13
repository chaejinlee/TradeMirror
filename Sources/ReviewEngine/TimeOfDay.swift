import Foundation

/// **按开仓时间看盈亏** —— 几点开的仓赚钱、几点开的仓不赚。
///
/// ★ 用户 2026-10-03:「去分析下我最赚钱的时间段」→「做进 app 里」。
///
/// ★★ 这一页最容易做成「看着有规律,其实是噪声」:
///   53 笔分 7 段,每段 3–14 笔;那天的表上 11–13 点 −$1,792、9:30–11 点 +$2,948,
///   而**置换检验说七段之间的差别和随机分组差不多大(p ≈ 0.5)**。
///   ⇒ 这里除了画出来,还必须**替用户把「是不是巧合」算掉**,并且只在站得住时才说话。
///
/// 两个检验:
///   ① 整体:时段之间的差别比随机分组大吗(按排名做置换检验,单笔大单影响不了)。
///   ② 每段的**两头**:最好的一笔是不是异常地小(上方被封顶)、
///      最差的一笔是不是异常地轻(下方被托住)。用超几何**精确**算,不靠随机抽样。
///      门槛按检验次数收紧(Bonferroni)—— 7 段 × 2 头,随便看总能看出点什么。
///   那天唯一站得住的就是②:11:00–12:00 的 11 笔里最好的一笔 +$100,p = 0.0055。
public enum TimeOfDay {

    /// 时段边界(交易所时区,自午夜起的分钟)。开盘头半小时单独一段。
    public static let edges = [570, 600, 660, 720, 780, 840, 900, 960]

    public struct Slot: Sendable, Identifiable {
        public var id: Int
        public var start: Int        // 分钟
        public var end: Int
        public var trades: [Trade]
        public var summary: DistributionSummary
        /// 这一段的合计**主要靠一笔**(那一笔占这段盈亏绝对值之和的一半以上)。
        /// ★ 那天的 13:00–14:00 +$1,165 里有 +$1,040 是一笔 —— 看着是好时段,其实是一笔好单。
        public var hingesOnOneTrade: Bool
        /// `09:30`
        public var label: String { String(format: "%02d:%02d", start / 60, start % 60) }
    }

    /// 某一段两头的异常。
    public struct Extreme: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case cappedUpside, cappedDownside }
        public var slotID: Int
        public var kind: Kind
        /// 这一段最好(cappedUpside)或最差(cappedDownside)的那一笔。
        public var value: Double
        public var n: Int
        /// 随便挑 n 笔都这么极端的精确概率。
        public var p: Double
    }

    public struct Report: Sendable {
        public var slots: [Slot]
        /// 画图用:每一笔的开仓分钟和盈亏。
        public var points: [(trade: Trade, minute: Int, pnl: Double)]
        /// 进了时段统计的笔数。
        public var n: Int
        /// ★ 没进统计的,**各自说清楚为什么** —— 守恒:eligible = n + 三者之和。
        public var excludedPlaceholder: Int
        public var excludedEstimated: Int
        public var outsideHours: Int
        /// ① 整体检验的 p。样本不够时是 nil(不给一个看着很精确的数)。
        public var pOverall: Double?
        /// ② 过了门槛的那些。
        public var extremes: [Extreme]
        /// ② 的门槛(Bonferroni 之后)。
        public var threshold: Double
    }

    /// 至少这么多笔才做检验 —— 再少,p 值只会制造错觉。
    public static let minForTest = 20
    /// 每段至少这么多笔才检验它的两头。
    public static let minPerSlot = 5

    /// 开仓那一刻(交易所时区,自午夜起的分钟)。
    public static func entryMinute(_ t: Trade) -> Int? {
        guard let first = t.legs.flatMap({ t.openingFills(of: $0) }).map(\.time).min()
                ?? t.fills.map(\.time).min() else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        let c = cal.dateComponents([.hour, .minute], from: first)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    public static func report(_ trades: [Trade], permutations: Int = 2000,
                              seed: UInt64 = 0x5EED_2026_1003) -> Report {
        let eligible = Distribution.eligible(trades)
        var placeholder = 0, estimated = 0, outside = 0
        var pts: [(trade: Trade, minute: Int, pnl: Double)] = []
        for t in eligible {
            let opens = t.legs.flatMap { t.openingFills(of: $0) }
            if opens.contains(where: \.timeIsEstimated) { estimated += 1; continue }
            if t.entryLooksLikeLegacyDefaultTime { placeholder += 1; continue }
            // ★★ 按**美分**取整再比 —— 2026-10-03 装进 App 用真实数据一看,
            //   11:00 那段的概率显示 0.38%,测试和外面的分析都是 0.55%。
            //   查下来:用户三笔「正好赚 $100」里有一笔引擎算出来是 100.000000000000227,
            //   于是「≤ $100」时它被算成「比 $100 大」。<b>浮点误差改变了结论</b>(还正好在门槛附近)。
            //   测试没抓到,是因为测试数据读自 CSV,那里已经四舍五入成 100.00 了 ——
            //   <b>又一次「测试用的数据和真实数据不一样」</b>。金额本来就只精确到分。
            guard let m = entryMinute(t), let raw = t.displayablePnL else { estimated += 1; continue }
            let p = cents(raw)
            if m < edges.first! || m >= edges.last! { outside += 1; continue }
            pts.append((t, m, p))
        }

        var slots: [Slot] = []
        for i in 0..<(edges.count - 1) {
            let inSlot = pts.filter { $0.minute >= edges[i] && $0.minute < edges[i + 1] }
            let ts = inSlot.map(\.trade)
            let s = Distribution.summary(ts)
            let pnls = inSlot.map(\.pnl)
            let absSum = pnls.map(abs).reduce(0, +)
            let hinges = pnls.count >= 2 && absSum > 0 && (pnls.map(abs).max() ?? 0) / absSum > 0.5
            slots.append(Slot(id: i, start: edges[i], end: edges[i + 1], trades: ts,
                              summary: s, hingesOnOneTrade: hinges))
        }

        // ── ① 整体 ──
        let all = pts.map(\.pnl)
        var pOverall: Double?
        if pts.count >= minForTest {
            let groups = pts.map { p in slots.firstIndex { p.minute >= $0.start && p.minute < $0.end }! }
            pOverall = permutationP(values: ranks(all), groups: groups, n: permutations, seed: seed)
        }

        // ── ② 两头 ──
        var tests: [Extreme] = []
        if pts.count >= minForTest {
            let N = all.count
            for s in slots where s.trades.count >= minPerSlot {
                let v = pts.filter { $0.minute >= s.start && $0.minute < s.end }.map(\.pnl)
                let k = v.count
                if let hi = v.max() {
                    let m = all.filter { $0 <= hi }.count
                    tests.append(Extreme(slotID: s.id, kind: .cappedUpside, value: hi, n: k,
                                         p: hypergeomAll(m: m, N: N, k: k)))
                }
                if let lo = v.min() {
                    let m = all.filter { $0 >= lo }.count
                    tests.append(Extreme(slotID: s.id, kind: .cappedDownside, value: lo, n: k,
                                         p: hypergeomAll(m: m, N: N, k: k)))
                }
            }
        }
        let threshold = tests.isEmpty ? 0 : 0.05 / Double(tests.count)

        return Report(slots: slots, points: pts, n: pts.count,
                      excludedPlaceholder: placeholder, excludedEstimated: estimated,
                      outsideHours: outside, pOverall: pOverall,
                      extremes: tests.filter { $0.p < threshold }.sorted { $0.p < $1.p },
                      threshold: threshold)
    }

    // MARK: - 统计小件

    /// 取整到分。
    static func cents(_ x: Double) -> Double { Money.cents(x) }

    /// 从 N 个里随机挑 k 个,**全部**落在那 m 个里的概率 = C(m,k) / C(N,k)。
    /// ★ 按乘积算,不算阶乘 —— 阶乘到 60 就溢出了。
    static func hypergeomAll(m: Int, N: Int, k: Int) -> Double {
        guard k <= m, k <= N, k >= 0 else { return 0 }
        var p = 1.0
        for i in 0..<k { p *= Double(m - i) / Double(N - i) }
        return p
    }

    /// 平均名次(并列取平均)。
    static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for x in i...j { r[order[x]] = avg }
            i = j + 1
        }
        return r
    }

    /// 组间平方和。
    static func between(_ v: [Double], _ g: [Int]) -> Double {
        let mean = v.reduce(0, +) / Double(max(1, v.count))
        var sum: [Int: Double] = [:], cnt: [Int: Int] = [:]
        for (x, k) in zip(v, g) { sum[k, default: 0] += x; cnt[k, default: 0] += 1 }
        return sum.keys.reduce(0) { acc, k in
            let n = Double(cnt[k]!); let m = sum[k]! / n
            return acc + n * (m - mean) * (m - mean)
        }
    }

    /// 置换检验。★ **固定种子** —— 同一份数据每次打开都得到同一个数,
    ///   不然 p 值在 0.048 和 0.052 之间跳,结论就跟着跳。
    static func permutationP(values: [Double], groups: [Int], n: Int, seed: UInt64) -> Double {
        let obs = between(values, groups)
        var rng = SplitMix64(seed: seed)
        var g = groups
        var hits = 0
        for _ in 0..<n {
            for i in stride(from: g.count - 1, to: 0, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1)); g.swapAt(i, j)
            }
            if between(values, g) >= obs - 1e-9 { hits += 1 }
        }
        return Double(hits + 1) / Double(n + 1)        // 加一:p 永远不是 0
    }
}

/// 可复现的随机数(SplitMix64)。系统那个不能设种子。
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
