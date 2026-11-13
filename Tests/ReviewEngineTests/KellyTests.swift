import XCTest
@testable import ReviewEngine

/// 凯利仓位。
///
/// ★★ 这一层守的是:**那个数旁边必须摆着它有多不可靠。**
///   2026-10-04 用户的 55 笔 QQQ 期权:满凯利 33%,可按交易日重抽 90% 区间 0%–78%,
///   12% 的重抽里平均每笔 ≤ 0;再多一笔归零就掉到 23%;照满凯利再做 100 笔,86% 会回撤过半。
///   这些数和外面 Python 分析(工作日志 #182)对得上,才算引擎算对了。
final class KellyTests: XCTestCase {

    /// (平仓日, 收益率 = 盈亏 ÷ 权利金)—— 2026-10-03 从用户手机拷下来、经引擎导出的 55 笔已平仓 QQQ 期权。
    static let real: [(String, Double)] = [
        ("2026-08-03", 0.402778), ("2026-08-05", 0.445545), ("2026-08-06", 0.215909), ("2026-08-06", 0.274112),
        ("2026-08-28", 0.545455), ("2026-08-28", -0.783333), ("2026-08-31", 0.121622), ("2026-08-31", 0.223684),
        ("2026-08-31", 0.807826), ("2026-09-01", 0.798507), ("2026-09-02", 1.114035), ("2026-09-02", 0.187158),
        ("2026-09-02", -0.441805), ("2026-09-03", 1.596154), ("2026-09-03", 0.345324), ("2026-09-03", 0.168317),
        ("2026-09-03", -0.538462), ("2026-09-04", 0.242489), ("2026-09-04", -0.900201), ("2026-09-08", -0.896396),
        ("2026-09-15", 0.342667), ("2026-09-15", -0.294872), ("2026-09-15", -0.535021), ("2026-09-21", 1.024390),
        ("2026-09-21", 0.217391), ("2026-09-21", 0.280878), ("2026-09-22", 0.236002), ("2026-09-22", 0.254545),
        ("2026-09-22", -0.579832), ("2026-09-22", 0.358974), ("2026-09-23", 0.056497), ("2026-09-23", -0.277228),
        ("2026-09-23", 0.185714), ("2026-09-23", 0.657895), ("2026-09-23", 0.166667), ("2026-09-24", -0.492913),
        ("2026-09-24", 0.057851), ("2026-09-24", 0.131579), ("2026-09-24", 0.125000), ("2026-09-24", -0.349650),
        ("2026-09-24", -0.576271), ("2026-09-24", 0.082391), ("2026-09-24", -0.635891), ("2026-09-25", -0.441026),
        ("2026-09-30", 0.123457), ("2026-09-30", 0.079439), ("2026-09-30", 0.136986), ("2026-09-30", 0.137566),
        ("2026-09-30", -0.220238), ("2026-09-30", 0.115152), ("2026-09-30", -0.274074), ("2026-10-01", 0.315152),
        ("2026-10-02", 0.024691), ("2026-10-02", -0.197499), ("2026-10-02", 0.125000),    ]

    static let realReport = Kelly.report(samples: realSamples)

    static var realSamples: [Kelly.Sample] {
        real.enumerated().map { i, x in
            Kelly.Sample(day: x.0, r: x.1, debit: 500, at: Date(timeIntervalSince1970: Double(i) * 3600))
        }
    }

    private func day(_ s: String, _ h: Int = 10) -> Date {
        let p = s.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = h
        c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    /// 一笔期权:开仓付 premium,平仓收回 premium × (1 + r)。
    private func option(_ d: String, r: Double, premium: Double = 500, credit: Bool = false,
                        closed: Bool = true, sample: Bool = false) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: day(d, 16)))
        let px = premium / 100
        let open = Fill(legID: leg.id, time: day(d, 10), side: credit ? .sell : .buy, quantity: 1, price: px)
        let close = Fill(legID: leg.id, time: day(d, 11), side: credit ? .buy : .sell, quantity: 1,
                         price: credit ? px * (1 - r) : px * (1 + r))
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: closed ? [open, close] : [open])
        t.isSample = sample
        return t
    }
    private func stock(_ d: String, pnl: Double) -> Trade {
        let leg = Leg(kind: .equity)
        return Trade(symbol: "TQQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: day(d, 10), side: .buy, quantity: 100, price: 50),
            Fill(legID: leg.id, time: day(d, 11), side: .sell, quantity: 100, price: 50 + pnl / 100)])
    }

    // ── 真实战绩 ───────────────────────────────────────────────────

    func testRealRecordGivesAboutAThird() {
        let rep = Self.realReport
        XCTAssertEqual(rep.n, 55)
        XCTAssertEqual(rep.days, 19)
        XCTAssertEqual(rep.winRate, 38.0 / 55, accuracy: 1e-9)
        XCTAssertEqual(rep.avgWin, 0.335, accuracy: 0.001)
        XCTAssertEqual(rep.avgLoss, 0.496, accuracy: 0.001)
        XCTAssertEqual(rep.fStar, 0.334, accuracy: 0.001)
        XCTAssertFalse(rep.capped)
        XCTAssertEqual(rep.worst, -0.9002, accuracy: 0.0001)
        XCTAssertEqual(rep.wipeouts, 0)
    }

    /// ★ 简化公式 23% 是「每笔愿意亏掉的比例」;换成权利金是 47% —— 比真实分布算出的 33% 还激进,
    ///   因为它假设每笔亏损都正好等于平均值,而他有两笔亏了 90%。
    func testTheSimpleFormulaIsAboutRiskNotPremium() throws {
        let rep = Self.realReport
        let simple = try XCTUnwrap(rep.simple)
        XCTAssertEqual(simple, 0.233, accuracy: 0.001)
        XCTAssertEqual(simple / rep.avgLoss, 0.47, accuracy: 0.005)
        XCTAssertGreaterThan(simple / rep.avgLoss, rep.fStar)
    }

    /// ★★ 这个 33% 自己的误差 —— 这一页存在的理由。
    func testTheEstimateIsVeryUncertain() {
        let rep = Self.realReport
        XCTAssertEqual(rep.p5, 0, accuracy: 1e-12)                 // 5% 分位就是「一分都不押」
        XCTAssertEqual(rep.p50, 0.34, accuracy: 0.04)
        XCTAssertEqual(rep.p95, 0.78, accuracy: 0.06)
        XCTAssertEqual(rep.pNoEdge, 0.117, accuracy: 0.025)
    }

    /// 0DTE 拿到收盘没走就是 −100%。这 55 笔还没出现过 —— 补上一笔,数就大变。
    func testOneWipeoutMovesItALot() {
        let rep = Self.realReport
        XCTAssertEqual(rep.withRuin.count, 3)
        XCTAssertEqual(rep.withRuin[0], 0.234, accuracy: 0.002)
        XCTAssertEqual(rep.withRuin[1], 0.150, accuracy: 0.002)
        XCTAssertEqual(rep.withRuin[2], 0.079, accuracy: 0.002)
    }

    /// 照满凯利再做 100 笔,大多数路径会回撤过半;¼ 凯利很少 —— 但不是没有:
    ///   模拟要先重抽「可能的真实战绩」,不然「其实没有优势」的情形被抹掉,¼ 凯利会只剩 0.9%。
    func testFullKellyUsuallyHalvesTheAccountAlongTheWay() {
        let rep = Self.realReport
        XCTAssertEqual(rep.risks.map(\.multiple), [0.25, 0.5, 1])
        XCTAssertEqual(rep.risks[2].pHalfDrawdown, 0.86, accuracy: 0.05)
        XCTAssertEqual(rep.risks[1].pHalfDrawdown, 0.34, accuracy: 0.06)
        XCTAssertEqual(rep.risks[0].pHalfDrawdown, 0.06, accuracy: 0.04)
        XCTAssertLessThan(rep.risks[0].pLoss, rep.risks[2].pLoss)
        XCTAssertLessThan(rep.risks[0].medianDrawdown, rep.risks[1].medianDrawdown)
        XCTAssertLessThan(rep.risks[1].medianDrawdown, rep.risks[2].medianDrawdown)
    }

    func testGrowthPeaksAtFStarAndTurnsNegativeAtTwice() {
        let r = Self.real.map(\.1)
        let f = Kelly.fStar(r).f
        XCTAssertGreaterThan(Kelly.growth(f, r), Kelly.growth(f - 0.05, r))
        XCTAssertGreaterThan(Kelly.growth(f, r), Kelly.growth(f + 0.05, r))
        // 半凯利留住约 75% 的增长;两倍凯利增长已经是负的
        XCTAssertEqual(Kelly.growth(f / 2, r) / Kelly.growth(f, r), 0.75, accuracy: 0.03)
        XCTAssertLessThan(Kelly.growth(2 * f, r), 0)
    }

    /// 同样的输入,同样的输出 —— 否则每次打开数字都在跳,用户会以为数据变了。
    func testDeterministic() {
        let a = Kelly.report(samples: Self.realSamples), b = Kelly.report(samples: Self.realSamples)
        XCTAssertEqual(a.p95, b.p95); XCTAssertEqual(a.pNoEdge, b.pNoEdge); XCTAssertEqual(a.risks, b.risks)
    }

    // ── 回撤风险表(自选倍数 / 按回撤标准反查)────────────────────────

    /// ★ 和工作日志 #185 的 Python 模拟对得上(100 笔)。
    func testGridMatchesTheAnalysis() throws {
        let g = try XCTUnwrap(Self.realReport.grid)
        XCTAssertEqual(g.multiples.count, 20)
        XCTAssertEqual(g.horizons, [100, 250])
        let q = try XCTUnwrap(g.at(0.25, horizon: 100)), h = try XCTUnwrap(g.at(0.5, horizon: 100))
        XCTAssertEqual(q.pDrawdown[0], 0.61, accuracy: 0.05)
        XCTAssertEqual(q.pDrawdown[1], 0.29, accuracy: 0.05)
        XCTAssertEqual(q.pDrawdown[2], 0.06, accuracy: 0.04)
        XCTAssertEqual(h.pDrawdown[1], 0.79, accuracy: 0.05)
        XCTAssertEqual(h.pDrawdown[2], 0.35, accuracy: 0.06)
        let q250 = try XCTUnwrap(g.at(0.25, horizon: 250))
        XCTAssertEqual(q250.pDrawdown[2], 0.17, accuracy: 0.05)
    }

    /// 期限越长,回撤只会更深(短期限是长期限的前缀);门槛越深,碰到的概率只会更小。
    /// ★ 这两条必须**逐格精确**成立 —— 不是统计上大致成立。
    func testLongerIsNeverShallowerAndDeeperIsNeverMoreLikely() throws {
        let g = try XCTUnwrap(Self.realReport.grid)
        for d in 0..<3 { for m in 0..<20 { XCTAssertGreaterThanOrEqual(g.p[1][d][m], g.p[0][d][m]) } }
        for m in 0..<20 { XCTAssertGreaterThanOrEqual(g.medianDrawdown[1][m], g.medianDrawdown[0][m]) }
        for h in 0..<2 { for m in 0..<20 {
            XCTAssertGreaterThanOrEqual(g.p[h][0][m], g.p[h][1][m])
            XCTAssertGreaterThanOrEqual(g.p[h][1][m], g.p[h][2][m])
        } }
    }

    /// ★ 反查和 #185 对得上;而且查出来的倍数**确实**满足那条标准,再往上一档就不满足。
    func testReverseLookupOnTheRealRecord() throws {
        let g = try XCTUnwrap(Self.realReport.grid)
        let cases: [(Double, Double, Double, Double)] = [   // 深度、概率、#185 的结果、容差
            (0.2, 0.10, 0.10, 0.03), (0.3, 0.10, 0.15, 0.03), (0.5, 0.10, 0.29, 0.04), (0.5, 0.05, 0.23, 0.04),
        ]
        for (depth, prob, want, tol) in cases {
            let c = try XCTUnwrap(g.maxMultiple(depth: depth, prob: prob, horizon: 100), "\(depth) \(prob)")
            XCTAssertEqual(c, want, accuracy: tol, "\(depth) \(prob)")
            let d = Kelly.RiskGrid.depths.firstIndex(of: depth)!
            XCTAssertLessThanOrEqual(try XCTUnwrap(g.at(c, horizon: 100)).pDrawdown[d], prob + 1e-9)
            XCTAssertGreaterThan(try XCTUnwrap(g.at(min(1, c + 0.05), horizon: 100)).pDrawdown[d], prob)
        }
    }

    /// 合成的表:插值、找不到、顶到满凯利、曲线不单调时取第一次越线。
    func testReverseLookupMechanics() throws {
        let ms = [0.2, 0.4, 0.6, 0.8, 1.0]
        func grid(_ ys: [Double]) -> Kelly.RiskGrid {
            Kelly.RiskGrid(multiples: ms, horizons: [100], p: [[ys, ys, ys]],
                           medianDrawdown: [[0.1, 0.2, 0.3, 0.4, 0.5]], pLoss: [[0, 0, 0, 0, 0]])
        }
        let g = grid([0.02, 0.05, 0.08, 0.12, 0.20])
        XCTAssertEqual(try XCTUnwrap(g.maxMultiple(depth: 0.3, prob: 0.10, horizon: 100)), 0.7, accuracy: 1e-12)
        XCTAssertNil(g.maxMultiple(depth: 0.3, prob: 0.01, horizon: 100))            // 连最小的都超标
        XCTAssertEqual(g.maxMultiple(depth: 0.3, prob: 0.50, horizon: 100), 1.0)     // 满凯利也达标
        XCTAssertNil(g.maxMultiple(depth: 0.3, prob: 0.10, horizon: 250))            // 没有这个期限
        // 模拟噪声让曲线回落:取**第一次**越线(0.36),不是最后一个达标的格点(0.6)
        let wobbly = grid([0.02, 0.12, 0.08, 0.20, 0.30])
        XCTAssertEqual(try XCTUnwrap(wobbly.maxMultiple(depth: 0.3, prob: 0.10, horizon: 100)), 0.36, accuracy: 1e-12)
        // 插值与夹边
        XCTAssertEqual(try XCTUnwrap(g.at(0.5, horizon: 100)).medianDrawdown, 0.25, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(g.at(0.0, horizon: 100)).multiple, 0.2)
        XCTAssertEqual(try XCTUnwrap(g.at(3.0, horizon: 100)).multiple, 1.0)
    }

    /// ★ 「再做 100 笔」换算成几个月 —— 按**他实际的节奏**,不是按「每天都做」(10-04 我在这上面错过一次)。
    func testMonthsFollowHisActualPace() throws {
        XCTAssertEqual(Kelly.weekdays("2026-08-03", "2026-10-02"), 45)
        XCTAssertEqual(Kelly.weekdays("2026-10-02", "2026-10-05"), 2)            // 周五、周一
        XCTAssertEqual(try XCTUnwrap(Self.realReport.months(for: 100)), 3.9, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(Self.realReport.months(for: 250)), 9.7, accuracy: 0.2)
    }

    /// 少押的代价:增长速度 ≈ c(2 − c) × 满凯利 —— 他的数据和公式几乎重合。
    func testGrowthShareFollowsCTimesTwoMinusC() {
        for c in [0.1, 0.15, 0.25, 0.5] {
            XCTAssertEqual(Self.realReport.growthShare(c), c * (2 - c), accuracy: 0.01)
        }
        XCTAssertEqual(Self.realReport.growthShare(1), 1, accuracy: 1e-12)
    }

    // ── 甜点区 ────────────────────────────────────────────────────

    /// ★ 和工作日志 #187 的 Python 对得上:偏差校正 0.24× · 解析 0.57× · 两层重抽 0.75×。
    func testSweetSpotMatchesTheAnalysis() throws {
        let s = try XCTUnwrap(Self.realReport.sweet)
        XCTAssertEqual(s.biasCorrected, 0.24, accuracy: 0.07)
        XCTAssertEqual(s.plugIn, 0.57, accuracy: 0.05)
        XCTAssertEqual(s.doubleBootstrap, 0.75, accuracy: 0.10)
        XCTAssertEqual(s.low, s.biasCorrected)
        XCTAssertEqual(s.high, s.doubleBootstrap)
        // 押多的代价:1.2× 剩约 63%,1.5× 剩约 22%,越往上越少。
        // ★ 2026-10-05 我在 Python 里把上限写成 0.999/|最差一笔|(能到 111% 预算),
        //   算出「1.2× 只剩三分之一、1.5× 变负」—— 错了。买期权最多花 100% 预算;改正后是这两个数。
        XCTAssertEqual(s.share(at: 1.2), 0.63, accuracy: 0.10)
        XCTAssertEqual(s.share(at: 1.5), 0.22, accuracy: 0.12)
        XCTAssertLessThan(s.share(at: 1.5), s.share(at: 1.2))
        XCTAssertLessThan(s.share(at: 1.2), s.share(at: 1.0))
        XCTAssertEqual(s.share(at: s.doubleBootstrap), 1, accuracy: 1e-12)
    }

    /// 每承受 1% 回撤换来的增长:平滑往下走,**没有拐点**(0.020 → 0.014)。
    func testEfficiencyDeclinesSmoothlyOnTheRealRecord() throws {
        let e = try XCTUnwrap(Self.realReport.efficiency(horizon: 100))
        XCTAssertEqual(e.first!, 0.020, accuracy: 0.002)
        XCTAssertEqual(e.last!, 0.014, accuracy: 0.002)
        XCTAssertNil(Self.realReport.efficiencyKnee(horizon: 100))
        XCTAssertNil(Self.realReport.efficiencyKnee(horizon: 250))
    }

    /// 拐点探测本身:平滑的不报,真有一截悬崖的要报出那一步。
    func testKneeDetector() {
        let ms = (1...10).map { Double($0) / 10 }
        let smooth = ms.map { 0.02 - 0.006 * $0 }
        XCTAssertNil(Kelly.knee(smooth, multiples: ms))
        var cliff = smooth
        for i in 6..<10 { cliff[i] -= 0.004 }                      // 0.6 → 0.7 之间掉一大截
        XCTAssertEqual(Kelly.knee(cliff, multiples: ms), 0.6)
        XCTAssertNil(Kelly.knee(ms.map { _ in 0.02 }, multiples: ms))  // 平的,不往下走
    }

    /// 优势还不到一个标准误:偏差校正那一端是 0 —— 甜点区从 0 开始,不硬给一个正数。
    func testWeakEdgeStartsTheSweetSpotAtZero() throws {
        let xs = (0..<40).map { i in
            Kelly.Sample(day: "2026-09-\(String(format: "%02d", 1 + i % 10))",
                         r: i % 2 == 0 ? 0.62 : -0.58, debit: 500,
                         at: Date(timeIntervalSince1970: Double(i)))
        }
        let rep = Kelly.report(samples: xs, resamples: 1500, paths: 500, worlds: 800)
        let s = try XCTUnwrap(rep.sweet)
        XCTAssertEqual(s.biasCorrected, 0)
        XCTAssertEqual(s.low, 0)
    }

    // ── 边界 ──────────────────────────────────────────────────────

    /// 平均每笔不赚钱 ⇒ 凯利的答案是 0,也就没有「按凯利做 100 笔」可模拟。
    func testNoEdgeGivesZero() {
        let xs = (0..<30).map { Kelly.Sample(day: "2026-09-\(String(format: "%02d", 1 + $0 % 10))",
                                             r: $0 % 2 == 0 ? 0.3 : -0.4, debit: 500,
                                             at: Date(timeIntervalSince1970: Double($0))) }
        let rep = Kelly.report(samples: xs)
        XCTAssertEqual(rep.fStar, 0)
        XCTAssertTrue(rep.risks.isEmpty)
    }

    /// 全是赚的 ⇒ 曲线一路往上,顶到 100% —— 必须标出来,这时的数没有意义。
    func testAllWinnersHitTheCeilingAndSaySo() {
        let r = [Double](repeating: 0.2, count: 25)
        let s = Kelly.fStar(r)
        XCTAssertEqual(s.f, 1); XCTAssertTrue(s.capped)
    }

    /// 已经有一笔亏光:f 不能到 100%(那一笔会把账户清零),曲线也得是有限的数。
    func testAWipeoutKeepsItBelowFull() {
        let r = [0.5, 0.5, 0.5, -1.0]
        let s = Kelly.fStar(r)
        XCTAssertLessThan(s.f, 1); XCTAssertFalse(s.capped)
        XCTAssertTrue(Kelly.growth(s.f, r).isFinite)
    }

    func testTooFewTradesIsNotEnough() {
        let rep = Kelly.report(samples: Array(Self.realSamples.prefix(12)))
        XCTAssertFalse(rep.enough)
        XCTAssertTrue(rep.risks.isEmpty)
    }

    // ── 哪些算进来 ────────────────────────────────────────────────

    /// ★ 只算付权利金开仓、已平仓、不是示例的期权;股票和卖方单独计数,说清没算哪几笔。
    func testOnlyClosedLongOptionsCount() {
        let trades = [
            option("2026-09-15", r: 0.5),
            option("2026-09-15", r: -0.25),
            option("2026-09-16", r: 0.3, credit: true),
            option("2026-09-16", r: 0.9, closed: false),
            option("2026-09-17", r: 2.0, sample: true),
            stock("2026-09-17", pnl: 120),
        ]
        let s = Kelly.samples(trades)
        XCTAssertEqual(s.samples.map(\.r).map { ($0 * 1000).rounded() / 1000 }, [0.5, -0.25])
        XCTAssertEqual(s.samples.map(\.day), ["2026-09-15", "2026-09-15"])
        XCTAssertEqual(s.samples.map(\.debit), [500, 500])
        XCTAssertEqual(s.nonOption, 1)
        XCTAssertEqual(s.credit, 1)
    }

    /// 「现在每笔用多少」看最近 20 笔 —— 他的仓位一直在变大。
    func testCurrentUseLooksAtTheRecentTrades() throws {
        var xs = Self.realSamples
        for i in xs.indices { xs[i].debit = i < 35 ? 100 : 600 }
        let rep = Kelly.report(samples: xs)
        XCTAssertEqual(rep.recentCount, 20)
        XCTAssertEqual(rep.recentMedianDebit, 600)
        let c = try XCTUnwrap(rep.current(budget: 6000))
        XCTAssertEqual(c.fraction, 0.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(c.ofKelly), 0.1 / rep.fStar, accuracy: 1e-12)
        XCTAssertNil(rep.current(budget: 0))
    }
}
