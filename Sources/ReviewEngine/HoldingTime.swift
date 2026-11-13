import Foundation

/// **持仓时间** —— 每一笔拿了多久,以及拿多久和赚没赚钱有没有关系。
///
/// ★ 用户 2026-10-06:「增加持仓时间功能」。
///
/// ★★ 他自己的数据里最站得住的一条:**赢单中位拿 8 分钟,亏单中位拿 20 分钟**
///   (那天 60 笔,两组持仓时长差这么多,随机分组做到的概率约 1%)——
///   赚了早走,亏了拿着等回本。反倒是「拿得越久越亏」这种整体趋势说不准(p ≈ 0.11)。
///   ⇒ 和按开仓时间那一节同一条规矩:表照列,**结论只说算过之后站得住的**。
///
/// 口径:
///   · 持仓时长 = **第一笔开仓 → 最后一笔平仓**(加仓、分批平都包在里面)。
///   · 开仓或平仓时间是**估的**、或者是旧版没认出时间时填的 11:00 ⇒ 不知道拿了多久,
///     不显示、不进统计,而且说清楚没算几笔。
///   · 隔夜单(平仓和开仓不在同一个交易日)单独一段 —— 拿了一夜和盘中拿了两小时不是一回事。
public extension Trade {

    /// 第一笔开仓到最后一笔平仓的秒数。未平仓、时间是估的、或旧版占位 ⇒ nil。
    var holdingSeconds: TimeInterval? {
        guard isClosed,
              let o = legs.flatMap({ openingFills(of: $0) }).min(by: { $0.time < $1.time }),
              let c = legs.flatMap({ closingFills(of: $0) }).max(by: { $0.time < $1.time }),
              !o.timeIsEstimated, !c.timeIsEstimated,
              !entryLooksLikeLegacyDefaultTime, !looksLikeLegacyDefaultTime
        else { return nil }
        return max(0, c.time.timeIntervalSince(o.time))
    }

    /// 开仓和平仓不在同一个交易日(交易所时区)。
    var heldOvernight: Bool {
        guard let o = legs.flatMap({ openingFills(of: $0) }).map(\.time).min(),
              let c = legs.flatMap({ closingFills(of: $0) }).map(\.time).max()
        else { return false }
        return TradingDay.key(of: o) != TradingDay.key(of: c)
    }
}

public enum HoldingTime {

    /// 分段边界(秒):2 分、5 分、15 分、30 分、1 小时。再往后是「1 小时以上(当天)」和「隔夜」。
    /// ★ 短的一头切得细:他一半的单子 11 分钟以内就走了。
    public static let edges: [TimeInterval] = [120, 300, 900, 1800, 3600]
    public static let bucketCount = edges.count + 2
    public static let overnightBucket = edges.count + 1
    /// 少于这么多笔不给 p 值;赢单、亏单各自至少这么多笔才比较两组。
    public static let minForTest = 20
    public static let minPerSide = 5

    public struct Bucket: Sendable, Identifiable {
        public var id: Int
        public var trades: [Trade]
        public var summary: DistributionSummary
        /// 这一段的合计**主要靠一笔**(那一笔占这段盈亏绝对值之和的一半以上)。
        public var hingesOnOneTrade: Bool
    }

    public struct Report: Sendable {
        public var buckets: [Bucket]
        public var points: [(trade: Trade, seconds: TimeInterval, pnl: Double)]
        public var n: Int
        /// 时间是估的、或旧版 11:00 占位 —— 不知道拿了多久。
        public var excluded: Int
        public var wins: Int
        public var losses: Int
        public var medianWinHold: TimeInterval?
        public var medianLossHold: TimeInterval?
        /// 赢单和亏单的持仓时长差这么多,随机分组做到的概率(按秩、双侧置换)。样本不够时 nil。
        public var pHoldDiffers: Double?
        /// 持仓时长和盈亏的 Spearman 相关,以及它的置换 p 值(双侧)。样本不够时 nil。
        public var rho: Double?
        public var pRho: Double?
    }

    /// 落在哪一段。隔夜单不看时长,单独一段。
    public static func bucket(seconds: TimeInterval, overnight: Bool) -> Int {
        if overnight { return overnightBucket }
        return edges.firstIndex { seconds < $0 } ?? edges.count
    }

    public static func report(_ trades: [Trade], permutations: Int = 4000,
                              seed: UInt64 = 0x40_1D_2026_1006) -> Report {
        var pts: [(trade: Trade, seconds: TimeInterval, pnl: Double)] = []
        var excluded = 0
        for t in Distribution.eligible(trades) {
            // ★ 盈亏按美分取整再比较(见 `Money.cents`)
            guard let s = t.holdingSeconds, let raw = t.displayablePnL else { excluded += 1; continue }
            pts.append((t, s, Money.cents(raw)))
        }

        var groups = [[(trade: Trade, seconds: TimeInterval, pnl: Double)]](repeating: [], count: bucketCount)
        for p in pts { groups[bucket(seconds: p.seconds, overnight: p.trade.heldOvernight)].append(p) }
        let buckets = groups.enumerated().map { i, g -> Bucket in
            let absSum = g.reduce(0) { $0 + abs($1.pnl) }
            let biggest = g.map { abs($0.pnl) }.max() ?? 0
            return Bucket(id: i, trades: g.map(\.trade),
                          summary: Distribution.summary(g.map(\.trade)),
                          hingesOnOneTrade: g.count >= 2 && absSum > 0 && biggest > absSum / 2)
        }

        let wins = pts.filter { $0.pnl > 0 }, losses = pts.filter { $0.pnl <= 0 }
        var rep = Report(buckets: buckets, points: pts, n: pts.count, excluded: excluded,
                         wins: wins.count, losses: losses.count,
                         medianWinHold: Distribution.median(wins.map(\.seconds)),
                         medianLossHold: Distribution.median(losses.map(\.seconds)),
                         pHoldDiffers: nil, rho: nil, pRho: nil)
        guard pts.count >= minForTest else { return rep }

        var rng = SplitMix64(seed: seed)
        let holdRanks = TimeOfDay.ranks(pts.map(\.seconds))
        if wins.count >= minPerSide, losses.count >= minPerSide {
            rep.pHoldDiffers = rankGapP(holdRanks, isWin: pts.map { $0.pnl > 0 },
                                        n: permutations, rng: &rng)
        }
        let pnlRanks = TimeOfDay.ranks(pts.map(\.pnl))
        let r = pearson(holdRanks, pnlRanks)
        rep.rho = r
        rep.pRho = correlationP(holdRanks, pnlRanks, observed: r, n: permutations, rng: &rng)
        return rep
    }

    /// 两组平均秩之差(绝对值)—— 赢单和亏单的持仓时长是不是从同一个池子里随机分出来的。
    static func rankGapP(_ ranks: [Double], isWin: [Bool], n: Int, rng: inout SplitMix64) -> Double {
        func gap(_ labels: [Bool]) -> Double {
            var sw = 0.0, sl = 0.0, cw = 0.0, cl = 0.0
            for i in ranks.indices { if labels[i] { sw += ranks[i]; cw += 1 } else { sl += ranks[i]; cl += 1 } }
            return abs(sw / max(cw, 1) - sl / max(cl, 1))
        }
        let observed = gap(isWin)
        var labels = isWin, hits = 0
        for _ in 0..<n {
            labels.shuffle(using: &rng)
            if gap(labels) >= observed - 1e-12 { hits += 1 }
        }
        return Double(hits + 1) / Double(n + 1)
    }

    /// 把盈亏的秩打乱 n 次,看有多少次的相关(绝对值)不小于实际的。
    static func correlationP(_ x: [Double], _ y: [Double], observed: Double, n: Int,
                             rng: inout SplitMix64) -> Double {
        var yy = y, hits = 0
        for _ in 0..<n {
            yy.shuffle(using: &rng)
            if abs(pearson(x, yy)) >= abs(observed) - 1e-12 { hits += 1 }
        }
        return Double(hits + 1) / Double(n + 1)
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        guard n > 1 else { return 0 }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }

    /// `4 分钟` / `1 小时 33 分` / `2 天 3 小时` / `不到 1 分钟`。
    /// ★ 引擎里不许出现裸中文 —— 译文由调用方传进来。
    public static func format(_ s: TimeInterval, _ L: (String) -> String = { $0 }) -> String {
        let minutes = Int((s / 60).rounded())
        if minutes < 1 { return L("不到 1 分钟") }
        if minutes < 60 { return String(format: L("%lld 分钟"), minutes) }
        if minutes < 24 * 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? String(format: L("%lld 小时"), h)
                          : String(format: L("%1$lld 小时 %2$lld 分"), h, m)
        }
        let d = minutes / (24 * 60), h = (minutes % (24 * 60)) / 60
        return h == 0 ? String(format: L("%lld 天"), d)
                      : String(format: L("%1$lld 天 %2$lld 小时"), d, h)
    }
}
