import XCTest
@testable import ReviewEngine

/// 单笔盈亏的分布(直方图)。
///
/// ★★ 这一层的两条命根子:
///   ① <b>0 必须落在箱子边界上</b> —— 横跨 0 的柱子会把赚的和亏的混进同一根,那根柱子在说谎。
///   ② <b>每笔恰好落进一个箱子</b> —— 和 `ImportTally.balances` 同一个形状的守卫。
///     这个项目已经在「东西悄悄消失」上栽过两次(导入丢成交、导入丢截图)。
final class DistributionTests: XCTestCase {

    /// 造一笔**已平仓**、盈亏正好等于 `pnl` 的交易。
    /// `adds` = 同向加仓几次。
    private func trade(_ pnl: Double, adds: Int = 0, reason: String? = nil,
                       sample: Bool = false) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: close))
        // 开仓 (adds+1) 笔各 1 张 @ $1;平仓 1 笔,价格反推出想要的盈亏
        let n = Double(adds + 1)
        var fills = (0...adds).map { i in
            Fill(legID: leg.id, time: close.addingTimeInterval(Double(-600 + i)),
                 side: .buy, quantity: 1, price: 1)
        }
        fills.append(Fill(legID: leg.id, time: close, side: .sell,
                          quantity: n, price: (n * 100 + pnl) / (n * 100)))
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills)
        t.exitReason = reason
        t.isSample = sample
        return t
    }

    /// 一笔**未平仓**的。
    private func openTrade() -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 18
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: close))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                     fills: [Fill(legID: leg.id, time: close, side: .buy, quantity: 1, price: 1)])
    }

    private func sanity() {
        XCTAssertEqual(trade(250).displayablePnL ?? 0, 250, accuracy: 1e-6, "夹具自己得先对")
        XCTAssertEqual(trade(-893, adds: 6).displayablePnL ?? 0, -893, accuracy: 1e-6)
    }
    func testTheFixtureItselfIsRight() { sanity() }

    // ── 谁能进 ──────────────────────────────────────────────────────

    /// ★ 未平仓不进 —— 没有已实现盈亏。和热力图、胜率同一条规矩。
    func testOpenTradesAreExcluded() {
        let xs = Distribution.eligible([trade(100), openTrade(), trade(-50)])
        XCTAssertEqual(xs.count, 2)
    }

    /// 示例数据不进 —— 那是给新用户看的,不是他的战绩。
    func testSampleTradesAreExcluded() {
        XCTAssertEqual(Distribution.eligible([trade(100), trade(50, sample: true)]).count, 1)
    }

    func testEmptyInputGivesNoBins() {
        XCTAssertTrue(Distribution.bins([]).isEmpty)
        XCTAssertTrue(Distribution.bins([openTrade()]).isEmpty)
    }

    // ── ★★ 0 在边界上 ───────────────────────────────────────────────

    /// <b>没有任何一个箱子可以横跨 0。</b>
    func testNoBinStraddlesZero() {
        let bins = Distribution.bins([trade(-893), trade(-140), trade(57),
                                      trade(261), trade(1236)], width: 200)
        XCTAssertFalse(bins.isEmpty)
        for b in bins {
            XCTAssertFalse(b.lo < 0 && b.hi > 0,
                           "[\(b.lo), \(b.hi)) 横跨 0 —— 赚的和亏的会混进同一根柱子")
        }
        XCTAssertTrue(bins.contains { $0.lo == 0 }, "必须有一档正好从 0 开始")
    }

    /// 盈亏正好 0 的一笔归到**非负**那一侧(`[0, w)`)。
    func testExactlyZeroLandsInTheNonNegativeBin() {
        let bins = Distribution.bins([trade(0)], width: 200)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0].lo, 0)
        XCTAssertTrue(bins[0].isProfit)
    }

    /// 边界值落在**左闭**那一侧:−200 属于 [−200, 0),不属于 [−400, −200)。
    func testBoundariesAreLeftClosed() {
        let bins = Distribution.bins([trade(-200), trade(200)], width: 200)
        let lows = bins.filter { $0.count > 0 }.map(\.lo)
        XCTAssertEqual(Set(lows), Set([-200.0, 200.0]))
    }

    // ── ★★ 守恒 ─────────────────────────────────────────────────────

    /// <b>每一笔恰好进一个箱子,一笔都不许丢。</b>
    func testEveryTradeLandsInExactlyOneBin() {
        let xs = [-893.0, -796, -634, -186, -140, -115, -94, 0, 45, 57, 68, 96,
                  113, 137, 162, 225, 261, 261, 264, 321, 340, 381, 498, 1236]
            .map { trade($0) }
        for w in [50.0, 100, 200, 250, 500, 1000] {
            let bins = Distribution.bins(xs, width: w)
            XCTAssertEqual(bins.reduce(0) { $0 + $1.count }, xs.count,
                           "档宽 \(w):进箱 \(bins.reduce(0) { $0 + $1.count }) ≠ 总数 \(xs.count)")
        }
    }

    /// 箱子必须**连续无缝**,中间的空档保留 —— 挖个洞正是分布要给人看的东西。
    func testBinsAreContiguousAndKeepTheGaps() {
        let bins = Distribution.bins([trade(-893), trade(100)], width: 200)
        for (a, b) in zip(bins, bins.dropFirst()) {
            XCTAssertEqual(a.hi, b.lo, accuracy: 1e-9, "箱子之间不许有缝")
        }
        XCTAssertTrue(bins.contains { $0.count == 0 }, "中间的空档要留着")
    }

    // ── 档宽自适应 ──────────────────────────────────────────────────

    /// ★★ 仓位变大时档宽必须跟着长。用户 8 月做 1–5 张、9 月做 20–33 张 ——
    ///   <b>写死的档宽过几周就不够用了。</b>
    func testBinWidthGrowsWithPositionSize() {
        let small = Distribution.binWidth([-140, 57, 261, 498])
        let big   = Distribution.binWidth([-8930, 570, 2610, 12360])
        XCTAssertLessThan(small, big, "数字大一个量级,档宽也该大一个量级")
        XCTAssertGreaterThan(big / small, 5)
    }

    /// 档宽只取 1 / 2 / 5 × 10ⁿ —— $237 一档没人看得懂。
    func testBinWidthSnapsToANiceLadder() {
        for vs in [[-140.0, 1236], [-8930, 12360], [-1.4, 12.3], [-89300, 123600]] {
            let w = Distribution.binWidth(vs)
            let mag = pow(10, floor(log10(w)))
            XCTAssertTrue([1.0, 2, 5, 10].contains((w / mag).rounded()),
                          "档宽 \(w) 不在 1/2/5 阶梯上")
        }
    }

    /// 档数落在能看的范围里。
    /// ★★ 第一版写的是 `3...40` —— **太松了**:实测选出 5 档,
    ///   23 笔里有 14 笔挤进同一根柱子,图完全没用,而测试是绿的。
    ///   <b>又一条绿着的守卫。</b>
    func testBinCountStaysReadable() {
        for vs in [[-140.0, 57, 261, 498, 1236], [-8930, -7960, 5700, 12360],
                   [-0.5, 0.3, 1.2], [-100000.0, 250000]] {
            let n = Distribution.bins(vs.map { trade($0) }).count
            XCTAssertTrue((8...30).contains(n), "\(vs) 分出 \(n) 档,看不了")
        }
    }

    /// ★★ 真正的判据不是档数,是**有没有一根柱子吃掉了大半样本**。
    ///   拿用户 2026-09-18 的真实 23 笔钉住。
    func testNoSingleBinSwallowsMostOfTheSample() {
        let real = [261.0, 225, 57, 162, 264, -94, 45, 68, 261, 321, 381, 137,
                    -186, 96, 498, 340, -140, 113, -893, -796, 1236, -115, -634]
        let bins = Distribution.bins(real.map { trade($0) })
        let biggest = bins.map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(biggest, real.count / 3,
            "最高那根有 \(biggest)/\(real.count) 笔 —— 档宽太粗,形状全被压平了。共 \(bins.count) 档")
    }

    /// 全是同一个数(零跨度)也不许崩、不许除零。
    func testDegenerateInputsDoNotCrash() {
        XCTAssertFalse(Distribution.bins([trade(0), trade(0)]).isEmpty)
        XCTAssertFalse(Distribution.bins([trade(250)]).isEmpty)
        XCTAssertGreaterThan(Distribution.binWidth([0, 0]), 0)
        XCTAssertGreaterThan(Distribution.binWidth([]), 0)
    }

    // ── 汇总 ────────────────────────────────────────────────────────

    /// 拿用户 2026-09-18 的真实 23 笔对答案。
    func testSummaryMatchesTheRealExport() {
        let real = [261.0, 225, 57, 162, 264, -94, 45, 68, 261, 321, 381, 137,
                    -186, 96, 498, 340, -140, 113, -893, -796, 1236, -115, -634]
        let s = Distribution.summary(real.map { trade($0) })
        XCTAssertEqual(s.n, 23)
        XCTAssertEqual(s.wins, 16)
        XCTAssertEqual(s.losses, 7)
        XCTAssertEqual(s.total, 1607, accuracy: 1)
        XCTAssertEqual(s.winRate ?? 0, 16.0 / 23.0, accuracy: 1e-9)
        XCTAssertEqual(s.avgWin ?? 0, 279, accuracy: 1)
        XCTAssertEqual(s.avgLoss ?? 0, -408, accuracy: 1)
        XCTAssertEqual(s.payoffRatio ?? 0, 0.68, accuracy: 0.01)
        XCTAssertEqual(s.best ?? 0, 1236, accuracy: 1)
        XCTAssertEqual(s.worst ?? 0, -893, accuracy: 1)
    }

    /// ★★ 只有盈利单时**不给盈亏比** —— 编一个 `∞` 或者 `0` 都是在骗人。
    ///   这条是本 App 反复守的那一类:<b>没有证据就说不知道。</b>
    func testPayoffRatioNeedsBothSides() {
        let onlyWins = Distribution.summary([trade(100), trade(200)])
        XCTAssertNil(onlyWins.avgLoss)
        XCTAssertNil(onlyWins.payoffRatio)
        XCTAssertNil(onlyWins.expectancy)
        let onlyLosses = Distribution.summary([trade(-100)])
        XCTAssertNil(onlyLosses.avgWin)
        XCTAssertNil(onlyLosses.payoffRatio)
        let both = Distribution.summary([trade(100), trade(-50)])
        XCTAssertEqual(both.payoffRatio ?? 0, 2, accuracy: 1e-9)
    }

    /// 没样本时统统是 nil,不是 0。
    func testEmptySummaryIsAllNil() {
        let s = Distribution.summary([])
        XCTAssertEqual(s.n, 0)
        XCTAssertNil(s.winRate); XCTAssertNil(s.avgWin)
        XCTAssertNil(s.best); XCTAssertNil(s.payoffRatio)
    }

    // ── 切片 ────────────────────────────────────────────────────────

    /// ★★ 这一刀是数据自己指出来的:用户那 23 笔里,加仓 ≥3 次的 2 笔合计 −$1,689,
    ///   <b>比他全部净利润($1,607)还多</b>。
    func testAddsBucketsReproduceTheRealSplit() {
        let xs = [trade(261, adds: 2), trade(225), trade(57), trade(162, adds: 1),
                  trade(264), trade(-94), trade(45), trade(68), trade(261),
                  trade(321), trade(381), trade(137, adds: 1), trade(-186, adds: 1),
                  trade(96), trade(498), trade(340, adds: 1), trade(-140),
                  trade(113, adds: 1), trade(-893, adds: 6), trade(-796, adds: 5),
                  trade(1236, adds: 2), trade(-115), trade(-634, adds: 2)]
        let g = Dictionary(uniqueKeysWithValues: Distribution.byAdds(xs))
        XCTAssertEqual(g[.none]?.count, 13)
        XCTAssertEqual(g[.few]?.count, 8)
        XCTAssertEqual(g[.many]?.count, 2)
        let deep = (g[.many] ?? []).compactMap(\.displayablePnL).reduce(0, +)
        XCTAssertEqual(deep, -1689, accuracy: 1)
        XCTAssertEqual(Distribution.summary(g[.many] ?? []).wins, 0, "那 2 笔一次都没赢")
        // ★ 守恒:切片不许把交易切没了
        XCTAssertEqual(g.values.reduce(0) { $0 + $1.count }, 23)
    }

    func testAddCountCountsSameSideOpensOnly() {
        XCTAssertEqual(Distribution.addCount(trade(100)), 0)
        XCTAssertEqual(Distribution.addCount(trade(100, adds: 6)), 6)
    }

    /// ★ 「没填」和「填了其他」是两件事,不许合并。
    func testUnsetExitReasonIsItsOwnGroup() {
        let g = Distribution.byExitReason([trade(1, reason: "触及目标"),
                                           trade(2, reason: "其他"),
                                           trade(3), trade(4, reason: "")])
        let keys = g.map { $0.0 }
        XCTAssertTrue(keys.contains(nil), "没填的要单独成组")
        XCTAssertTrue(keys.contains("其他"))
        XCTAssertEqual(g.first { $0.0 == nil }?.1.count, 2, "空字符串也算没填")
        XCTAssertEqual(g.reduce(0) { $0 + $1.1.count }, 4, "切片不许丢")
    }
}

/// 平均盈利% / 平均亏损%。用户 2026-09-22:「盈亏分布添加平均盈利%以及平均亏损%」。
///
/// ★★ 这一层的要害不是算平均,是**谁能进这个平均**:
///   贷记开仓的 `returnOnDebit` 是 nil(分母不对),那些笔必须被排除,
///   而且<b>界面要看得出被排除了几笔</b> —— 否则「平均 49%」会被当成全部的平均。
final class DistributionPercentTests: XCTestCase {

    /// 造一笔:买 `qty` 张 @ `entry`,平在 `exit`。收益率 = (exit−entry)/entry。
    private func debitTrade(qty: Double, entry: Double, exit: Double) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 22
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: close))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: close.addingTimeInterval(-600),
                 side: .buy, quantity: qty, price: entry),
            Fill(legID: leg.id, time: close, side: .sell, quantity: qty, price: exit)])
    }

    /// **贷记开仓**:先卖后买。`returnOnDebit` 必须是 nil。
    private func creditTrade(qty: Double, entry: Double, exit: Double) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 22
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .put, strike: 700, expiry: close))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: close.addingTimeInterval(-600),
                 side: .sell, quantity: qty, price: entry),
            Fill(legID: leg.id, time: close, side: .buy, quantity: qty, price: exit)])
    }

    func testFixturesAreWhatIThinkTheyAre() {
        let d = debitTrade(qty: 10, entry: 1, exit: 1.5)
        XCTAssertEqual(d.displayablePnL ?? 0, 500, accuracy: 1e-6)
        XCTAssertEqual(d.returnOnDebit ?? 0, 0.5, accuracy: 1e-9)
        let c = creditTrade(qty: 10, entry: 1, exit: 0.4)
        XCTAssertEqual(c.displayablePnL ?? 0, 600, accuracy: 1e-6)
        XCTAssertNil(c.returnOnDebit, "★ 贷记开仓没有可信的分母")
    }

    // ── 用户的真实 23 笔 ────────────────────────────────────────────

    /// ★★ 对答案:平均盈 <b>+48.9%</b>,平均亏 <b>−62.7%</b>。
    func testMatchesTheRealExport() {
        // (张数, 开仓价, 平仓价) —— 反推自 2026-09-18 的导出
        let real: [(Double, Double, Double)] = [
            (3, 2.16, 3.03), (10, 0.505, 0.73), (1, 2.64, 3.21), (3, 1.97, 2.51),
            (4, 1.21, 1.87), (1, 1.20, 0.26), (5, 0.74, 0.83), (4, 0.76, 0.93),
            (8, 0.4038, 0.73), (3, 1.34, 2.41), (3, 1.14, 2.41), (11, 0.66545455, 0.79),
            (5, 0.842, 0.47), (2, 1.39, 1.87), (3, 1.04, 2.70), (40, 0.505, 0.59),
            (10, 0.26, 0.12), (3, 1.55333333, 1.93), (33, 0.30060303, 0.03),
            (23, 0.38608696, 0.04), (29, 1.2437931, 1.67), (5, 0.78, 0.55),
            (19, 0.62368421, 0.29),
        ].map { $0 }
        let s = Distribution.summary(real.map { debitTrade(qty: $0.0, entry: $0.1, exit: $0.2) })
        XCTAssertEqual(s.n, 23)
        XCTAssertEqual(s.wins, 16)
        XCTAssertEqual(s.avgWinPct ?? 0, 0.489, accuracy: 0.002)
        XCTAssertEqual(s.avgLossPct ?? 0, -0.627, accuracy: 0.002)
        XCTAssertEqual(s.payoffRatioPct ?? 0, 0.78, accuracy: 0.01)
        XCTAssertTrue(s.pctCoversEveryTrade, "全是借记开仓,每笔都算得出")
        // ★ 中位数(2026-10-05 加):典型的亏单比平均小一半多 —— 平均被两笔 30 张左右的大亏拉下去了
        XCTAssertEqual(s.medianWin ?? 0, 242.98, accuracy: 0.01)
        XCTAssertEqual(s.medianLoss ?? 0, -186.00, accuracy: 0.01)
        XCTAssertEqual(s.medianWinPct ?? 0, 0.3440, accuracy: 0.0005)
        XCTAssertEqual(s.medianLossPct ?? 0, -0.5385, accuracy: 0.0005)
        XCTAssertLessThan(abs(s.medianLoss ?? 0), abs(s.avgLoss ?? 0) / 2)
    }

    // ── 中位数 ────────────────────────────────────────────────────

    /// 一笔大单能把平均拉走,拉不动中位数 —— 这正是要加中位数的原因。
    func testMedianIsTheTypicalTradeNotTheAverage() {
        // 10 张 @ $1 开仓,平仓价定盈亏:+$100 +$120 +$2000 −$50 −$60 −$900
        let s = Distribution.summary([1.1, 1.12, 3.0, 0.95, 0.94, 0.1].map { debitTrade(qty: 10, entry: 1, exit: $0) })
        XCTAssertEqual(s.avgWin ?? 0, 740, accuracy: 1e-9)
        XCTAssertEqual(s.medianWin ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(s.medianLoss ?? 0, -60, accuracy: 1e-9)
        XCTAssertEqual(s.medianPayoffRatio ?? 0, 2, accuracy: 1e-9)
    }

    /// 偶数个取中间两个的平均;空的一边给 nil,不给 0。
    func testMedianEvenCountAndEmptySide() {
        let s = Distribution.summary([1.1, 1.3].map { debitTrade(qty: 10, entry: 1, exit: $0) })   // +$100 +$300
        XCTAssertEqual(s.medianWin ?? 0, 200, accuracy: 1e-9)
        XCTAssertNil(s.medianLoss)
        XCTAssertNil(s.medianPayoffRatio)
        XCTAssertNil(Distribution.summary([]).medianWin)
    }

    /// ★★ 浮点误差不能改显示出来的数。2026-10-05 模拟器里中位盈显示 $121,正确是 $121.50(→ $122):
    ///   中间两笔是 $113 和 $130,可 $113 那笔引擎算出来是 112.99999999999997,平均下来差一丝不到 .5。
    ///   和 #179 的 p 值同一类错 ⇒ 盈亏先按美分取整再统计。
    func testFloatNoiseDoesNotMoveTheMedian() {
        let a = debitTrade(qty: 1, entry: 0.88, exit: 2.01)    // 112.99999999999997
        let b = debitTrade(qty: 1, entry: 0.01, exit: 1.31)    // 130(正好)
        XCTAssertLessThan(a.displayablePnL ?? 0, 113, "夹具本身:这笔必须带着误差")
        let s = Distribution.summary([a, b])
        XCTAssertEqual(s.medianWin, 121.5)
        XCTAssertEqual(s.avgWin, 121.5)
    }

    /// 百分比的中位数和平均同一条规矩:贷记开仓算不出百分比 ⇒ 不进来;金额照算。
    func testMedianPercentSkipsCreditTrades() {
        let s = Distribution.summary([
            debitTrade(qty: 1, entry: 1, exit: 1.5),   // +50%
            debitTrade(qty: 1, entry: 1, exit: 1.1),   // +10%
            debitTrade(qty: 1, entry: 1, exit: 1.2),   // +20%
            creditTrade(qty: 1, entry: 1, exit: 0.1),  // 赚 $90,没有百分比
        ])
        XCTAssertEqual(s.medianWinPct ?? 0, 0.20, accuracy: 1e-9)
        XCTAssertEqual(s.medianWin ?? 0, 35, accuracy: 1e-9, "金额四笔都算:$10 $20 $50 $90 的中位")
    }

    /// ★★ <b>两个口径会给出不同的结论,这不是 bug。</b>
    ///   金额问「一笔赚多少」,百分比问「一块钱赚多少」——
    ///   仓位大小不一样时两者必然分叉。
    func testAmountAndPercentDisagreeOnPurpose() {
        // 小仓位大涨幅 + 大仓位小跌幅
        let xs = [debitTrade(qty: 1, entry: 1, exit: 3),      // +$200, +200%
                  debitTrade(qty: 100, entry: 1, exit: 0.7)]  // −$3000, −30%
        let s = Distribution.summary(xs)
        XCTAssertLessThan(s.payoffRatio ?? 0, 0.1, "金额口径:惨不忍睹")
        XCTAssertGreaterThan(s.payoffRatioPct ?? 0, 6, "百分比口径:好看得很")
        XCTAssertNotEqual(s.payoffRatio, s.payoffRatioPct)
    }

    // ── ★★ 谁被排除了 ───────────────────────────────────────────────

    /// 贷记开仓**不进平均**,而且笔数要能看出差额。
    func testCreditTradesAreExcludedAndTheGapIsVisible() {
        let s = Distribution.summary([
            debitTrade(qty: 1, entry: 1, exit: 1.5),   // +50%
            debitTrade(qty: 1, entry: 1, exit: 1.3),   // +30%
            creditTrade(qty: 1, entry: 1, exit: 0.4),  // 赚了,但没有百分比
        ])
        XCTAssertEqual(s.wins, 3)
        XCTAssertEqual(s.winsWithPct, 2, "★ 3 笔盈利,只有 2 笔算得出百分比")
        XCTAssertEqual(s.avgWinPct ?? 0, 0.40, accuracy: 1e-9, "平均只能对那 2 笔算")
        XCTAssertFalse(s.pctCoversEveryTrade, "界面必须能看出差额")
    }

    /// 全是贷记开仓 ⇒ **一个百分比都不给**,不给 0。
    func testAllCreditGivesNoPercentAtAll() {
        let s = Distribution.summary([creditTrade(qty: 1, entry: 1, exit: 0.4),
                                      creditTrade(qty: 1, entry: 1, exit: 1.6)])
        XCTAssertEqual(s.n, 2)
        XCTAssertNil(s.avgWinPct); XCTAssertNil(s.avgLossPct)
        XCTAssertNil(s.payoffRatioPct)
        XCTAssertEqual(s.winsWithPct, 0); XCTAssertEqual(s.lossesWithPct, 0)
        XCTAssertNotNil(s.avgWin, "★ 金额照给 —— 那个算得出来")
    }

    /// 只有一边有样本 ⇒ 百分比盈亏比不给。和金额口径同一条规矩。
    func testPercentPayoffNeedsBothSides() {
        let s = Distribution.summary([debitTrade(qty: 1, entry: 1, exit: 1.5)])
        XCTAssertNotNil(s.avgWinPct)
        XCTAssertNil(s.avgLossPct)
        XCTAssertNil(s.payoffRatioPct)
    }

    /// 空输入全是 nil。
    func testEmpty() {
        let s = Distribution.summary([])
        XCTAssertNil(s.avgWinPct); XCTAssertNil(s.avgLossPct)
        XCTAssertEqual(s.winsWithPct, 0)
        XCTAssertTrue(s.pctCoversEveryTrade, "0 笔也算「都覆盖了」—— 不该报警")
    }

    /// 平局(盈亏 0)算在亏损那一侧,和金额口径一致,不许两边各算各的。
    func testBreakEvenGoesWithLossesInBothViews() {
        let s = Distribution.summary([debitTrade(qty: 1, entry: 1, exit: 1)])
        XCTAssertEqual(s.losses, 1)
        XCTAssertEqual(s.lossesWithPct, 1)
        XCTAssertEqual(s.avgLossPct ?? -1, 0, accuracy: 1e-9)
    }
}
