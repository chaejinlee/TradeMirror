import Foundation

/// **凯利仓位** —— 把你自己的战绩代进凯利公式,并且把「这个数有多不可靠」一起算出来。
///
/// ★ 用户 2026-10-04:「根据凯利公式以及我们的历史战绩来算最优仓位」→
///   「做进 app 里,我可以随时修改预算来计算对应仓位」。
///
/// ★★ 这一页最危险的做法,是给出一个精确到个位的「最优仓位」:
///   那天的 55 笔 QQQ 期权算出满凯利 33%,可是按交易日重抽,90% 区间是 0%–78%,
///   12% 的重抽里平均每笔 ≤ 0;再多一笔归零就掉到 23%;照满凯利再做 100 笔,86% 会回撤过半。
///   ⇒ 预算 × 比例照算,但**误差、归零、回撤必须和那个数摆在一起**。
///
/// 口径:
///   · 只算**付权利金开仓的期权**:最多亏光权利金,收益率 = 盈亏 ÷ 权利金。
///     股票的风险尺度完全不同,先收钱的卖方没有「本金」这个分母 —— 都不混进来,但说清没算哪几笔。
///   · f = 每笔权利金占预算的比例。买期权不能加杠杆,f 最多 100%。
///   · f* = 让「平均每笔 log(1 + f·r)」最大的 f —— 用**每一笔**的真实收益,
///     不用「平均赢 / 平均亏」两个数(那个简化公式假设每笔亏损都正好等于平均值)。
public enum Kelly {

    /// 少于这么多笔 / 这么多个交易日,不给数 —— 凯利对样本极其敏感。
    public static let minTrades = 20
    public static let minDays = 5
    /// 「你现在每笔用多少」看最近这么多笔:他的仓位一直在变(8 月 1–5 张,9 月 20–33 张)。
    public static let recentWindow = 20

    /// 进计算的一笔。
    public struct Sample: Sendable, Equatable {
        /// 交易日(交易所时区),重抽按它整天整天地抽。
        public var day: String
        /// 盈亏 ÷ 权利金。
        public var r: Double
        /// 付出去的权利金。
        public var debit: Double
        public var at: Date
        public init(day: String, r: Double, debit: Double, at: Date) {
            self.day = day; self.r = r; self.debit = debit; self.at = at
        }
    }

    /// 某一档仓位再做 `horizon` 笔的下场(模拟)。
    public struct Risk: Sendable, Equatable {
        /// 满凯利的几倍:0.25 / 0.5 / 1。
        public var multiple: Double
        public var f: Double
        /// 做完仍在亏的比例。
        public var pLoss: Double
        /// 途中回撤过 50% 的比例。
        public var pHalfDrawdown: Double
        public var medianDrawdown: Double
    }

    /// **倍数 × 期限的回撤风险表。**
    ///
    /// ★ 用户 2026-10-05:「在控制回撤的情况下应该使用多少凯利」→「做进去 app」。
    ///   用几成凯利取决于**他自己**能忍多深、要多大把握、看多长 —— App 不替他定,
    ///   只把「每个倍数会回撤多深」和「每条标准允许多大倍数」摆出来。
    public struct RiskGrid: Sendable, Equatable {
        /// 回撤深度:20% / 30% / 50%。
        public static let depths: [Double] = [0.2, 0.3, 0.5]
        /// 0.05×, 0.10×, …, 1.00×。★ 用 i / 20 生成,¼、½、1 都是精确的格点。
        public var multiples: [Double]
        /// 升序,比如 [100, 250]。
        public var horizons: [Int]
        /// p[期限][深度][倍数]:期限内回撤 ≥ 该深度的路径比例。
        public var p: [[[Double]]]
        public var medianDrawdown: [[Double]]
        /// 做完仍在亏的比例。
        public var pLoss: [[Double]]

        public struct Point: Sendable, Equatable {
            public var multiple: Double
            /// 对应 `depths`。
            public var pDrawdown: [Double]
            public var medianDrawdown: Double
            public var pLoss: Double
        }

        /// 任意倍数的那一行 —— 格点之间线性插值。
        public func at(_ c: Double, horizon: Int) -> Point? {
            guard let h = horizons.firstIndex(of: horizon), !multiples.isEmpty else { return nil }
            let x = min(max(c, multiples[0]), multiples[multiples.count - 1])
            return Point(multiple: x,
                         pDrawdown: p[h].map { Self.lerp(multiples, $0, x) },
                         medianDrawdown: Self.lerp(multiples, medianDrawdown[h], x),
                         pLoss: Self.lerp(multiples, pLoss[h], x))
        }

        /// 「回撤 ≥ depth 的概率不超过 prob」时,最多能用几倍满凯利。
        /// nil = 连最小的倍数都超标;顶到 1 = 满凯利也达标(不往上算 —— 超过满凯利,增长只会更慢)。
        /// ★ 取**第一次**越线的地方:模拟有噪声,概率曲线未必处处单调,第一次越线最保守。
        public func maxMultiple(depth: Double, prob: Double, horizon: Int) -> Double? {
            guard let h = horizons.firstIndex(of: horizon),
                  let d = Self.depths.firstIndex(where: { abs($0 - depth) < 1e-9 }) else { return nil }
            let ys = p[h][d]
            guard let first = ys.first, first <= prob else { return nil }
            for i in 1..<ys.count where ys[i] > prob {
                let t = (prob - ys[i - 1]) / (ys[i] - ys[i - 1])
                return multiples[i - 1] + t * (multiples[i] - multiples[i - 1])
            }
            return multiples.last
        }

        static func lerp(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
            guard xs.count > 1 else { return ys.first ?? 0 }
            var i = 0
            while i < xs.count - 2 && xs[i + 1] < x { i += 1 }
            let t = (x - xs[i]) / (xs[i + 1] - xs[i])
            return ys[i] + t * (ys[i + 1] - ys[i])
        }
    }

    /// **甜点区** —— 把「满凯利是从这几天估出来的」算进去以后,长期增长最大的倍数落在哪一段。
    ///
    /// ★ 用户 2026-10-05:「那能计算出最佳甜品点位的仓位吗」→「做进去 app」。
    ///   甜点位通常要拿增长换风险,换多少是偏好;这里只用一个**不需要偏好**的标准:
    ///   估出来的凯利可能偏大,照着押就会押多,而押多的代价比押少大 —— 所以增长最大的倍数小于 1。
    ///   三种算法(偏差校正 / 解析 / 两层重抽)那天给出 0.24× / 0.57× / 0.75×:差三倍,
    ///   因为都取决于「真实优势有多大」,而这正是那 19 天说不清的 ⇒ **给一段,不给一个点**。
    public struct SweetSpot: Sendable, Equatable {
        /// (μ̂² − Var)/μ̂² —— 把 μ̂² 对真实 μ² 的高估扣掉;优势还不到一个标准误时是 0。
        public var biasCorrected: Double
        /// μ̂²/(μ̂² + Var) —— 正态近似下「押 c 倍估计值」的最优 c。
        public var plugIn: Double
        /// 两层重抽的平均增长最大的格点。
        public var doubleBootstrap: Double
        /// 两层重抽的平均增长曲线(每笔对数增长),对应 `multiples`(0.05×–1.5×)。
        public var multiples: [Double]
        public var growth: [Double]

        public var low: Double { min(biasCorrected, plugIn, doubleBootstrap) }
        public var high: Double { min(1, max(biasCorrected, plugIn, doubleBootstrap)) }

        /// 押 `c` 倍时的平均增长占最大值的比例(押太多会变负)。
        public func share(at c: Double) -> Double {
            guard let top = growth.max(), top > 0 else { return 0 }
            return RiskGrid.lerp(multiples, growth, min(max(c, multiples.first ?? c), multiples.last ?? c)) / top
        }
    }

    public struct Report: Sendable {
        public var samples: [Sample]
        public var n: Int { samples.count }
        public var days: Int
        /// 没算进来的:股票等非期权 / 先收钱的卖方。
        public var excludedNonOption: Int
        public var excludedCredit: Int
        public var winRate: Double
        public var avgWin: Double
        /// 正数。
        public var avgLoss: Double
        public var worst: Double
        /// 已经归零(亏掉 ≥ 99%)过几笔。
        public var wipeouts: Int
        /// 常见简化公式 胜率 − 败率 ÷ 盈亏比。
        /// ★ 它是**每笔愿意亏掉的比例**,不是权利金比例 —— 换成权利金要再除以平均亏损率。没有赢或没有亏时为 nil。
        public var simple: Double?
        public var fStar: Double
        /// f* 顶到了 100%:数据里还没有足够的亏损来约束它 —— 这时这个数没有意义。
        public var capped: Bool
        /// 按交易日重抽出来的 f*:5% / 50% / 95% 分位。
        public var p5: Double, p50: Double, p95: Double
        /// 重抽里平均每笔 ≤ 0 的比例 —— 「这段战绩还证明不了有优势」的可能有多大。
        public var pNoEdge: Double
        public var resamples: Int
        /// 再加 1 / 2 / 3 笔 −100% 之后的 f*。
        public var withRuin: [Double]
        /// ¼ / ½ / 满凯利各再做 `horizon` 笔。
        public var risks: [Risk]
        public var horizon: Int
        /// 最近 `recentWindow` 笔每笔权利金的中位数,和预算一比就是「现在用的比例」。
        public var recentMedianDebit: Double
        public var recentCount: Int
        /// 「倍数 × 期限」的回撤风险表 —— 自选倍数、按回撤标准反查都查它。样本不够或没有优势时为 nil。
        public var grid: RiskGrid? = nil
        /// 第一笔到最后一笔之间有几个工作日 —— 用来把「再做 N 笔」换算成大约几个月。
        public var marketDays: Int = 0
        /// 甜点区(见 `SweetSpot`)。样本不够或没有优势时为 nil。
        public var sweet: SweetSpot? = nil

        /// 每承受 1% 的回撤(中位数)换来多少增长(占满凯利的比例)—— 对应 `grid.multiples`。
        public func efficiency(horizon h: Int) -> [Double]? {
            guard let g = grid, let i = g.horizons.firstIndex(of: h) else { return nil }
            return g.multiples.indices.map { k in
                let dd = g.medianDrawdown[i][k]
                return dd > 0 ? growthShare(g.multiples[k]) / (dd * 100) : 0
            }
        }

        /// 效率曲线有没有**拐点**:某一步掉得特别狠(超过总降幅的 25%,且超过步长中位数的 3 倍)。
        /// 有 ⇒ 返回那一步开始的倍数;平滑 ⇒ nil。
        /// ★ 「没有拐点」这句话必须是算出来的 —— 数据多了以后可能真长出一个来。
        public func efficiencyKnee(horizon h: Int) -> Double? {
            guard let e = efficiency(horizon: h), let g = grid else { return nil }
            return Kelly.knee(e, multiples: g.multiples)
        }

        public var enough: Bool { n >= Kelly.minTrades && days >= Kelly.minDays }

        /// 按过去的节奏,`h` 笔大约是几个月(每月按 21 个交易日)。
        /// ★ 2026-10-04 我按「每个交易日都在做」算成 1.6 个月,实际他 44 个交易日里只做了 19 天 —— 是 3.8 个月。
        public func months(for h: Int) -> Double? {
            guard n > 0, marketDays > 0 else { return nil }
            return Double(h) / (Double(n) / Double(marketDays)) / 21
        }

        /// 用 `c` 倍满凯利,长期增长速度是满凯利的几成。理论上 ≈ c(2 − c),他的数据几乎重合。
        public func growthShare(_ c: Double) -> Double {
            let r = samples.map(\.r), top = Kelly.growth(fStar, r)
            return top > 0 ? Kelly.growth(c * fStar, r) / top : 0
        }

        /// 现在每笔用的是预算的多少,以及是满凯利的几倍。没填预算或没有优势时为 nil。
        public func current(budget: Double) -> (fraction: Double, ofKelly: Double?)? {
            guard budget > 0, recentCount > 0 else { return nil }
            let f = recentMedianDebit / budget
            return (f, fStar > 0 ? f / fStar : nil)
        }
    }

    // MARK: - 哪些算进来

    /// ★ 用引擎自己的规则认:已平仓、不是示例、全部腿都是期权、而且是付钱开的仓。
    public static func samples(_ trades: [Trade]) -> (samples: [Sample], nonOption: Int, credit: Int) {
        var out: [Sample] = []
        var nonOption = 0, credit = 0
        for t in Distribution.eligible(trades) {
            let allOptions = !t.legs.isEmpty && t.legs.allSatisfy {
                if case .option = $0.kind { return true } else { return false }
            }
            guard allOptions else { nonOption += 1; continue }
            guard let r = t.returnOnDebit, let at = t.attributedAt else { credit += 1; continue }
            out.append(Sample(day: TradingDay.key(of: at), r: r, debit: t.netDebit, at: at))
        }
        return (out.sorted { $0.at < $1.at }, nonOption, credit)
    }

    // MARK: - 公式

    /// 平均每笔的对数增长 —— 凯利要最大化的那个数。
    public static func growth(_ f: Double, _ r: [Double]) -> Double {
        guard !r.isEmpty else { return 0 }
        return r.reduce(0) { $0 + log1p(f * $1) } / Double(r.count)
    }

    /// 满凯利。平均每笔不赚钱时是 0;`capped` = 顶到了 100%。
    ///
    /// ★ f 的上限:买期权不加杠杆 ⇒ 最多 100%;任何一笔都不能把账户亏到 0 以下
    ///   (有归零的那笔时上限是 0.999,带手续费亏过 100% 时再往下压)。
    /// ★ 增长曲线是凹的,它的斜率随 f 单调往下走 ⇒ 对斜率二分,稳,不靠步长。
    /// ★ 写成普通循环而不是 `reduce` + 闭包:重抽要调它 4,000 次,手机上装的是 Debug 包(不开优化),
    ///   闭包写法慢一个量级 —— 页面会转好几秒圈。
    public static func fStar(_ r: [Double]) -> (f: Double, capped: Bool) {
        r.withUnsafeBufferPointer { b in
            guard !b.isEmpty else { return (0, false) }
            var sum = 0.0, worst = 0.0
            for i in 0..<b.count { sum += b[i]; if b[i] < worst { worst = b[i] } }
            guard sum > 0 else { return (0, false) }
            let hi = worst <= -1 ? 0.999 / -worst : 1
            func slope(_ f: Double) -> Double {
                var acc = 0.0
                for i in 0..<b.count { acc += b[i] / (1 + f * b[i]) }
                return acc
            }
            if slope(hi) >= 0 { return (hi, true) }
            var a = 0.0, z = hi
            for _ in 0..<45 {             // 2⁻⁴⁵ ≈ 3e-14,够了
                let m = (a + z) / 2
                if slope(m) > 0 { a = m } else { z = m }
            }
            return ((a + z) / 2, false)
        }
    }

    // MARK: - 报告

    public static func report(_ trades: [Trade], resamples: Int = 4000, paths: Int = 4000,
                              worlds: Int = 2000, horizon: Int = 100,
                              seed: UInt64 = 0x4B31_2026_1004) -> Report {
        let s = samples(trades)
        return report(samples: s.samples, excludedNonOption: s.nonOption, excludedCredit: s.credit,
                      resamples: resamples, paths: paths, worlds: worlds, horizon: horizon, seed: seed)
    }

    public static func report(samples: [Sample], excludedNonOption: Int = 0, excludedCredit: Int = 0,
                              resamples: Int = 4000, paths: Int = 4000, worlds: Int = 2000,
                              horizon: Int = 100, seed: UInt64 = 0x4B31_2026_1004) -> Report {
        let r = samples.map(\.r)
        let wins = r.filter { $0 > 0 }, losses = r.filter { $0 <= 0 }
        let n = Double(max(r.count, 1))
        let p = Double(wins.count) / n
        let avgWin = wins.isEmpty ? 0 : wins.reduce(0, +) / Double(wins.count)
        let avgLoss = losses.isEmpty ? 0 : -losses.reduce(0, +) / Double(losses.count)
        let simple: Double? = (wins.isEmpty || avgLoss <= 0) ? nil : p - (1 - p) / (avgWin / avgLoss)
        let best = fStar(r)

        // 按交易日分组 —— 同一天的几笔不独立(同一个行情、同一个状态),重抽得整天整天地抽
        var order: [String] = [], byDayMap: [String: [Double]] = [:]
        for x in samples {
            if byDayMap[x.day] == nil { order.append(x.day) }
            byDayMap[x.day, default: []].append(x.r)
        }
        let byDay = order.map { byDayMap[$0]! }

        let recent = samples.suffix(recentWindow).map(\.debit).sorted()
        var rep = Report(samples: samples, days: byDay.count,
                         excludedNonOption: excludedNonOption, excludedCredit: excludedCredit,
                         winRate: r.isEmpty ? 0 : p, avgWin: avgWin, avgLoss: avgLoss,
                         worst: r.min() ?? 0, wipeouts: r.filter { $0 <= -0.99 }.count,
                         simple: simple, fStar: best.f, capped: best.capped,
                         p5: 0, p50: 0, p95: 0, pNoEdge: 0, resamples: resamples,
                         withRuin: (1...3).map { fStar(r + Array(repeating: -1, count: $0)).f },
                         risks: [], horizon: horizon,
                         recentMedianDebit: median(recent), recentCount: recent.count)
        if let a = samples.first?.day, let z = samples.last?.day { rep.marketDays = weekdays(a, z) }
        guard rep.enough else { return rep }

        var rng = SplitMix64(seed: seed)
        let b = bootstrap(byDay, resamples: resamples, rng: &rng)
        rep.p5 = b.p5; rep.p50 = b.p50; rep.p95 = b.p95; rep.pNoEdge = b.pNoEdge
        guard best.f > 0 else { return rep }
        // 甜点区:三种把「f* 是估出来的」算进去的算法
        let mu = r.reduce(0, +) / n, mu2 = mu * mu, v = b.meanVar
        let ms = (1...30).map { Double($0) / 20 }              // 0.05× … 1.50×(看得见押多的那一侧)
        let eg = doubleBootstrap(byDay, multiples: ms, worlds: worlds, rng: &rng)
        if let top = eg.indices.max(by: { eg[$0] < eg[$1] }), mu2 > 0 {
            rep.sweet = SweetSpot(biasCorrected: max(0, mu2 - v) / mu2, plugIn: mu2 / (mu2 + v),
                                  doubleBootstrap: ms[top], multiples: ms, growth: eg)
        }
        let grid = simulateGrid(byDay, fStar: best.f, multiples: (1...20).map { Double($0) / 20 },
                                horizons: Array(Set([horizon, 250])).sorted(), paths: paths, rng: &rng)
        rep.grid = grid
        if let h = grid.horizons.firstIndex(of: horizon), let half = RiskGrid.depths.firstIndex(of: 0.5) {
            rep.risks = [0.25, 0.5, 1].compactMap { m in
                guard let i = grid.multiples.firstIndex(of: m) else { return nil }
                return Risk(multiple: m, f: m * best.f, pLoss: grid.pLoss[h][i],
                            pHalfDrawdown: grid.p[h][half][i], medianDrawdown: grid.medianDrawdown[h][i])
            }
        }
        return rep
    }

    /// 一条往下走的曲线有没有「突然掉一大截」的那一步:超过总降幅的 25%,且超过步长中位数的 3 倍。
    /// 有 ⇒ 那一步开始的横坐标;平滑(或不往下走)⇒ nil。
    static func knee(_ e: [Double], multiples: [Double]) -> Double? {
        guard e.count > 2, e.count == multiples.count, let first = e.first, let last = e.last,
              first > last else { return nil }
        let drops = (1..<e.count).map { e[$0 - 1] - e[$0] }
        let med = drops.map(abs).sorted()[drops.count / 2]
        guard let k = drops.indices.max(by: { drops[$0] < drops[$1] }) else { return nil }
        return drops[k] > 0.25 * (first - last) && drops[k] > 3 * med ? multiples[k] : nil
    }

    /// 两个交易日(含两头)之间有几个工作日。★ 不扣节假日 —— 一年十来天,换算「大约几个月」够用。
    static func weekdays(_ a: String, _ b: String) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TradingDay.exchangeTimeZone
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
        }
        guard let x = date(a), let y = date(b), x <= y else { return 0 }
        var n = 0, d = x
        while d <= y {
            let w = cal.component(.weekday, from: d)
            if w != 1 && w != 7 { n += 1 }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return n
    }

    // MARK: - 有多可靠

    /// 整天整天地重抽,每次重算 f*。
    static func bootstrap(_ byDay: [[Double]], resamples: Int, rng: inout SplitMix64)
        -> (p5: Double, p50: Double, p95: Double, pNoEdge: Double, meanVar: Double) {
        guard !byDay.isEmpty, resamples > 0 else { return (0, 0, 0, 0, 0) }
        var fs: [Double] = []
        fs.reserveCapacity(resamples)
        var noEdge = 0
        var m1 = 0.0, m2 = 0.0                    // 重抽出来的「平均每笔」的一阶、二阶矩
        for _ in 0..<resamples {
            let x = redraw(byDay, rng: &rng)
            let sum = x.reduce(0, +)
            if sum <= 0 { noEdge += 1 }
            let mean = sum / Double(max(x.count, 1))
            m1 += mean; m2 += mean * mean
            fs.append(fStar(x).f)
        }
        fs.sort()
        let n = Double(resamples)
        return (quantile(fs, 0.05), quantile(fs, 0.5), quantile(fs, 0.95),
                Double(noEdge) / n, max(0, m2 / n - (m1 / n) * (m1 / n)))
    }

    /// 两层重抽:外层是一个「可能的真相」,内层是那个真相下你会看到的那几天、据此估出的凯利 f̂;
    /// 再在那个真相里按「c × f̂」下注,记平均每笔的对数增长。对所有真相取平均。
    /// ★ 外层不能省:在**同一份**数据上评估 c × f̂,f̂ 恰好是那份数据的最优解,c = 1 永远最好 ——
    ///   那就把「f̂ 是估出来的」这件事整个抹掉了。
    static func doubleBootstrap(_ byDay: [[Double]], multiples: [Double], worlds: Int,
                                rng: inout SplitMix64) -> [Double] {
        guard !byDay.isEmpty, worlds > 0, !multiples.isEmpty else { return [] }
        var acc = [Double](repeating: 0, count: multiples.count)
        let D = UInt64(byDay.count)
        for _ in 0..<worlds {
            var world: [[Double]] = []
            world.reserveCapacity(byDay.count)
            for _ in 0..<byDay.count { world.append(byDay[Int(rng.next() % D)]) }
            var sample: [Double] = []
            for _ in 0..<world.count { sample += world[Int(rng.next() % D)] }
            let fh = fStar(sample).f
            let wr = world.flatMap { $0 }
            let worst = wr.min() ?? 0
            let cap = worst <= -1 ? 0.999 / -worst : 1
            wr.withUnsafeBufferPointer { b in
                for i in 0..<multiples.count {
                    let f = min(multiples[i] * fh, cap)
                    var g = 0.0
                    for k in 0..<b.count { g += log1p(f * b[k]) }
                    acc[i] += g / Double(b.count)
                }
            }
        }
        return acc.map { $0 / Double(worlds) }
    }

    /// 每条路径:先整天重抽一份「可能的真实战绩」,再从里面连抽到最长的期限,
    /// 在每个期限上记一次「最深回撤」和「是不是还在亏」。
    /// ★ 先重抽这一步不能省 —— 省了就等于假设这 19 天就是真相。
    ///   实测(2026-10-04 的 55 笔):省掉以后 ¼ 凯利「回撤过半」从 6% 掉到 0.9%,
    ///   小仓位看起来几乎没风险 —— 因为「其实没有优势」的那 12% 被抹掉了。
    /// ★ 所有倍数共用同一串抽签:比较的是仓位,不是运气;短期限是长期限的前缀,所以期限越长回撤只会更深。
    static func simulateGrid(_ byDay: [[Double]], fStar: Double, multiples: [Double], horizons: [Int],
                             paths: Int, rng: inout SplitMix64) -> RiskGrid {
        let depths = RiskGrid.depths
        let nm = multiples.count, nh = horizons.count
        let longest = horizons.last ?? 0
        guard fStar > 0, !byDay.isEmpty, paths > 0, longest > 0, nm > 0 else {
            return RiskGrid(multiples: multiples, horizons: horizons, p: [], medianDrawdown: [], pLoss: [])
        }
        // 第 t 笔做完是不是某个期限的终点(是 ⇒ 期限的下标,不是 ⇒ −1)
        let marks = (0..<longest).map { horizons.firstIndex(of: $0 + 1) ?? -1 }
        // ★ 扁平存每条路径在每个期限、每个倍数上的「最深回撤」和「期末净值」,事后再数 ——
        //   内层循环里不碰嵌套数组(Debug 包里每次 `a[i][j][k] += 1` 都是好几次函数调用)
        var dd = [Double](repeating: 0, count: nh * nm * paths)
        var end = dd
        var seq = [Double](repeating: 0, count: longest)
        dd.withUnsafeMutableBufferPointer { ddb in
        end.withUnsafeMutableBufferPointer { eb in
        seq.withUnsafeMutableBufferPointer { sq in
        marks.withUnsafeBufferPointer { mk in
            for path in 0..<paths {
                let pool = redraw(byDay, rng: &rng)
                let n = UInt64(pool.count)
                // ★ 取模而不是 `Int.random(in:)`:池子只有几十笔,取模的偏差是 1e-17 量级
                pool.withUnsafeBufferPointer { pb in
                    for t in 0..<longest { sq[t] = pb[Int(rng.next() % n)] }
                }
                for mi in 0..<nm {
                    let f = multiples[mi] * fStar
                    var equity = 1.0, peak = 1.0, worst = 0.0
                    for t in 0..<longest {
                        let g = 1 + f * sq[t]
                        equity *= g > 0 ? g : 0
                        if equity > peak { peak = equity }
                        let d = 1 - equity / peak
                        if d > worst { worst = d }
                        let h = mk[t]
                        if h >= 0 {
                            let k = (h * nm + mi) * paths + path
                            ddb[k] = worst; eb[k] = equity
                        }
                    }
                }
            }
        }}}}
        let P = Double(paths)
        var p = [[[Double]]](), med = [[Double]](), loss = [[Double]]()
        for h in 0..<nh {
            var ph = [[Double]](repeating: [Double](repeating: 0, count: nm), count: depths.count)
            var mh = [Double](repeating: 0, count: nm), lh = mh
            for mi in 0..<nm {
                let lo = (h * nm + mi) * paths
                let xs = dd[lo..<(lo + paths)].sorted()
                for (di, depth) in depths.enumerated() {
                    // 排好序了:第一个 ≥ depth 的位置之后全是
                    var a = 0, b = xs.count
                    while a < b { let m = (a + b) / 2; if xs[m] >= depth { b = m } else { a = m + 1 } }
                    ph[di][mi] = Double(xs.count - a) / P
                }
                mh[mi] = median(xs)
                lh[mi] = Double(end[lo..<(lo + paths)].filter { $0 < 1 }.count) / P
            }
            p.append(ph); med.append(mh); loss.append(lh)
        }
        return RiskGrid(multiples: multiples, horizons: horizons, p: p, medianDrawdown: med, pLoss: loss)
    }

    static func redraw(_ byDay: [[Double]], rng: inout SplitMix64) -> [Double] {
        var x: [Double] = []
        x.reserveCapacity(byDay.count * 4)
        for _ in 0..<byDay.count { x += byDay[Int.random(in: 0..<byDay.count, using: &rng)] }
        return x
    }

    /// 线性插值分位(和 numpy 默认一致)。`sorted` 必须已排好序。
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    static func median(_ sorted: [Double]) -> Double { quantile(sorted, 0.5) }
}
