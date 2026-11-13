import XCTest
@testable import ReviewEngine

/// 按开仓时间看盈亏。
///
/// ★★ 这一层的要害不是分组,是**替用户把「是不是巧合」算掉**:
///   2026-10-03 那份真实数据里,表上 11–13 点 −$1,792、9:30–11 点 +$2,948,
///   而置换检验说七段之间的差别和随机分组差不多大。
///   只有「11:00–12:00 的 11 笔里最好的一笔只有 +$100」站得住(p = 0.0055)。
final class TimeOfDayTests: XCTestCase {

    private func date(_ day: String, _ h: Int, _ m: Int, sec: Int = 0) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        c.hour = h; c.minute = m; c.second = sec; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    /// 一笔:open 时刻买 100 股,close 时刻卖,盈亏正好 = pnl。
    private func trade(_ openDay: String, _ oh: Int, _ om: Int, _ closeDay: String, _ ch: Int, _ cm: Int,
                       _ pnl: Double, estimated: Bool = false, sample: Bool = false) -> Trade {
        let leg = Leg(kind: .equity)
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: date(openDay, oh, om), side: .buy, quantity: 100, price: 10,
                 timeIsEstimated: estimated),
            Fill(legID: leg.id, time: date(closeDay, ch, cm), side: .sell, quantity: 100,
                 price: 10 + pnl / 100)])
        t.isSample = sample
        return t
    }
    private func at(_ h: Int, _ m: Int, _ pnl: Double) -> Trade {
        trade("2026-09-15", h, m, "2026-09-15", min(15, h + 1), m, pnl)
    }

    /// (开仓日, 时, 分, 平仓日, 时, 分, 盈亏, 开仓时间是不是旧版占位)
    /// —— 2026-10-03 从用户手机上拷下来的 57 笔已平仓,盈亏由引擎算出。
    static let real: [(String, Int, Int, String, Int, Int, Double, Bool)] = [
        ("2026-08-03", 9, 53, "2026-08-03", 10, 29, 261.00, false), ("2026-08-05", 15, 30, "2026-08-05", 15, 48, 225.00, false),
        ("2026-08-06", 9, 44, "2026-08-06", 9, 54, 57.00, false), ("2026-08-06", 10, 30, "2026-08-06", 11, 2, 162.00, false),
        ("2026-08-28", 10, 47, "2026-08-28", 11, 1, 264.00, false), ("2026-08-28", 12, 39, "2026-08-28", 14, 40, -94.00, false),
        ("2026-08-31", 11, 37, "2026-08-31", 11, 54, 45.00, false), ("2026-08-31", 11, 55, "2026-08-31", 11, 59, 68.00, false),
        ("2026-08-31", 13, 36, "2026-08-31", 13, 43, 260.96, false), ("2026-09-01", 10, 13, "2026-09-01", 10, 35, 321.00, false),
        ("2026-09-02", 9, 57, "2026-09-02", 10, 19, 381.00, false), ("2026-09-02", 11, 0, "2026-09-02", 11, 0, 137.00, true),
        ("2026-09-02", 11, 52, "2026-09-02", 11, 52, -186.00, false), ("2026-09-03", 11, 0, "2026-09-03", 11, 0, 498.00, true),
        ("2026-09-03", 11, 0, "2026-09-03", 14, 2, 340.00, true), ("2026-09-03", 11, 0, "2026-09-03", 11, 0, 96.00, true),
        ("2026-09-03", 15, 29, "2026-09-03", 15, 43, -140.00, false), ("2026-09-04", 9, 53, "2026-09-04", 9, 59, 113.00, false),
        ("2026-09-04", 10, 14, "2026-09-04", 13, 31, -892.99, false), ("2026-09-08", 11, 42, "2026-09-08", 15, 19, -796.00, false),
        ("2026-09-15", 10, 38, "2026-09-15", 10, 52, 1236.00, false), ("2026-09-15", 12, 48, "2026-09-15", 12, 52, -115.00, false),
        ("2026-09-15", 12, 53, "2026-09-15", 13, 29, -634.00, false), ("2026-09-21", 10, 0, "2026-09-21", 10, 29, 1260.00, false),
        ("2026-09-21", 14, 44, "2026-09-21", 14, 52, 440.00, false), ("2026-09-21", 15, 37, "2026-09-21", 15, 39, 736.80, false),
        ("2026-09-22", 9, 36, "2026-09-22", 10, 13, 628.00, false), ("2026-09-22", 14, 9, "2026-09-22", 14, 21, 280.00, false),
        ("2026-09-22", 14, 23, "2026-09-22", 14, 57, -1380.00, false), ("2026-09-22", 15, 20, "2026-09-23", 10, 18, 41.69, false),
        ("2026-09-22", 15, 51, "2026-09-22", 15, 53, 140.00, false), ("2026-09-23", 10, 19, "2026-09-23", 10, 27, 100.00, false),
        ("2026-09-23", 11, 54, "2026-09-23", 12, 19, -168.00, false), ("2026-09-23", 12, 41, "2026-09-23", 12, 45, 130.00, false),
        ("2026-09-23", 15, 22, "2026-09-23", 15, 34, 250.00, false), ("2026-09-23", 15, 45, "2026-09-23", 15, 47, 100.00, false),
        ("2026-09-24", 9, 36, "2026-09-24", 11, 6, -626.00, false), ("2026-09-24", 11, 7, "2026-09-24", 11, 11, 35.00, false),
        ("2026-09-24", 11, 14, "2026-09-24", 11, 18, 90.00, false), ("2026-09-24", 11, 21, "2026-09-24", 11, 25, 100.00, false),
        ("2026-09-24", 11, 29, "2026-09-24", 11, 47, -250.00, false), ("2026-09-24", 13, 23, "2026-09-24", 13, 43, -136.00, false),
        ("2026-09-24", 15, 16, "2026-09-24", 15, 17, 51.00, false), ("2026-09-24", 15, 25, "2026-09-24", 15, 59, -489.00, false),
        ("2026-09-25", 10, 6, "2026-09-25", 10, 19, -172.00, false), ("2026-09-30", 10, 24, "2026-09-30", 10, 27, 60.00, false),
        ("2026-09-30", 10, 33, "2026-09-30", 10, 37, 51.00, false), ("2026-09-30", 10, 42, "2026-09-30", 10, 50, 60.00, false),
        ("2026-09-30", 10, 56, "2026-09-30", 11, 1, 52.00, false), ("2026-09-30", 11, 10, "2026-09-30", 11, 21, -74.00, false),
        ("2026-09-30", 11, 48, "2026-09-30", 11, 52, 57.00, false), ("2026-09-30", 15, 39, "2026-09-30", 15, 51, -111.00, false),
        ("2026-10-01", 13, 20, "2026-10-01", 13, 25, 1040.00, false), ("2026-10-02", 10, 17, "2026-10-02", 10, 23, 12.00, false),
        ("2026-10-02", 10, 24, "2026-10-02", 10, 30, -379.00, false), ("2026-10-02", 14, 59, "2026-10-02", 15, 10, 35.00, false),
        ("2026-10-02", 15, 31, "2026-10-02", 15, 39, 96.16, false),
    ]
    private func realTrades() -> [Trade] {
        Self.real.map { trade($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6) }
    }

    // ── 分到哪一段 ──────────────────────────────────────────────────

    func testSlotEdgesAreLeftClosed() {
        let r = TimeOfDay.report([at(9, 30, 1), at(9, 59, 2), at(10, 0, 3), at(15, 59, 4)])
        XCTAssertEqual(r.slots[0].trades.count, 2, "9:30 和 9:59 都在开盘那半小时")
        XCTAssertEqual(r.slots[1].trades.count, 1, "10:00 属于 10–11 点")
        XCTAssertEqual(r.slots[6].trades.count, 1, "15:59 属于尾盘")
    }

    /// ★ 按**交易所时区**分,夏令时前后都对。11 月第一个周日之后纽约是 UTC−5。
    func testExchangeTimeZoneAcrossDST() {
        let summer = trade("2026-09-15", 10, 15, "2026-09-15", 10, 30, 1)
        let winter = trade("2026-11-10", 10, 15, "2026-11-10", 10, 30, 1)
        XCTAssertEqual(TimeOfDay.entryMinute(summer), 615)
        XCTAssertEqual(TimeOfDay.entryMinute(winter), 615)
    }

    // ── 谁不进统计,而且要说清楚 ────────────────────────────────────

    /// ★★ 开仓时间是旧版 11:00 占位 —— 不进统计。
    ///   9/3 那笔 719C:两笔买入 11:00 占位、卖出 14:02 是真的,也要排除。
    func testLegacyPlaceholderEntryIsExcluded() {
        let allPlaceholder = trade("2026-09-03", 11, 0, "2026-09-03", 11, 0, 96)
        let entryOnly = trade("2026-09-03", 11, 0, "2026-09-03", 14, 2, 340)
        let r = TimeOfDay.report([allPlaceholder, entryOnly, at(10, 15, 1)])
        XCTAssertEqual(r.excludedPlaceholder, 2)
        XCTAssertEqual(r.n, 1)
        XCTAssertTrue(entryOnly.entryLooksLikeLegacyDefaultTime)
        XCTAssertFalse(entryOnly.looksLikeLegacyDefaultTime, "旧规则问的是「所有成交」—— 这笔它放过")
    }

    func testEstimatedEntryIsExcluded() {
        let r = TimeOfDay.report([trade("2026-09-15", 10, 0, "2026-09-15", 10, 30, 5, estimated: true),
                                  at(10, 15, 1)])
        XCTAssertEqual(r.excludedEstimated, 1)
        XCTAssertEqual(r.n, 1)
    }

    func testOutsideRegularHoursIsCountedNotDropped() {
        let pre = trade("2026-09-15", 8, 30, "2026-09-15", 9, 45, 10)
        let post = trade("2026-09-15", 16, 0, "2026-09-15", 16, 30, 10)
        let r = TimeOfDay.report([pre, post, at(10, 15, 1)])
        XCTAssertEqual(r.outsideHours, 2)
        XCTAssertEqual(r.n, 1)
    }

    /// ★★ 守恒:每一笔已平仓都有去处 —— 进了统计,或者被说明了为什么没进。
    func testEveryEligibleTradeIsAccountedFor() {
        let ts = realTrades() + [trade("2026-09-15", 10, 0, "2026-09-15", 10, 30, 5, estimated: true),
                                 trade("2026-09-15", 8, 0, "2026-09-15", 9, 40, 5),
                                 trade("2026-09-15", 10, 0, "2026-09-15", 10, 30, 5, sample: true)]
        let r = TimeOfDay.report(ts)
        let eligible = Distribution.eligible(ts).count
        XCTAssertEqual(r.n + r.excludedPlaceholder + r.excludedEstimated + r.outsideHours, eligible)
        XCTAssertEqual(r.slots.reduce(0) { $0 + $1.trades.count }, r.n)
    }

    // ── ★★ 用户的真实数据 ───────────────────────────────────────────

    /// 对答案:那天在外面算的每个数,引擎都要算得一样。
    func testRealDataMatchesTheOffAppAnalysis() {
        let r = TimeOfDay.report(realTrades())
        XCTAssertEqual(r.excludedPlaceholder, 4)
        XCTAssertEqual(r.n, 53)
        let totals = r.slots.map { Int($0.summary.total.rounded()) }
        XCTAssertEqual(totals, [814, 2134, -1079, -713, 1165, -625, 901])
        XCTAssertEqual(r.slots.map(\.trades.count), [6, 14, 11, 4, 3, 4, 11])
    }

    /// ★★ 整体**不显著** —— 表上那些红红绿绿,大部分是噪声。
    func testRealDataOverallIsNotSignificant() throws {
        let p = try XCTUnwrap(TimeOfDay.report(realTrades()).pOverall)
        XCTAssertGreaterThan(p, 0.1, "七段之间的差别和随机分组差不多大 —— 不该说成规律")
    }

    /// ★★ 唯一站得住的:11:00–12:00 最好的一笔 +$100,p ≈ 0.0055。
    func testRealDataFlagsOnlyTheMiddayCappedUpside() {
        let r = TimeOfDay.report(realTrades())
        XCTAssertEqual(r.extremes.count, 1, "只该有一条过门槛:\(r.extremes)")
        let e = r.extremes[0]
        XCTAssertEqual(r.slots[e.slotID].label, "11:00")
        XCTAssertEqual(e.kind, .cappedUpside)
        XCTAssertEqual(e.value, 100, accuracy: 0.01)
        XCTAssertEqual(e.n, 11)
        XCTAssertEqual(e.p, 0.0055, accuracy: 0.0005)
        XCTAssertLessThan(e.p, r.threshold)
        XCTAssertEqual(r.threshold, 0.05 / 8, accuracy: 1e-9, "5 笔以上的段 4 个 × 两头 = 8 次检验")
    }

    /// 一笔撑起来的段要标出来:13:00–14:00 的 +$1,165 里有 +$1,040 是一笔。
    func testHingesOnOneTrade() {
        let r = TimeOfDay.report(realTrades())
        XCTAssertTrue(r.slots[4].hingesOnOneTrade, "13:00 段")
        XCTAssertTrue(r.slots[5].hingesOnOneTrade, "14:00 段:−$1,380 那一笔")
        XCTAssertFalse(r.slots[1].hingesOnOneTrade, "10:00 段:去掉两头还有 +$1,767")
    }

    // ── 检验本身 ────────────────────────────────────────────────────

    /// 样本不够就**不给 p 值** —— 一个看着很精确的数只会制造错觉。
    func testTooFewTradesGivesNoVerdict() {
        let r = TimeOfDay.report((0..<10).map { at(10, $0, Double($0 * 10)) })
        XCTAssertNil(r.pOverall)
        XCTAssertTrue(r.extremes.isEmpty)
    }

    /// ★ 固定种子:同一份数据每次都得到同一个 p —— 不然结论会在门槛两边跳。
    func testPermutationIsDeterministic() {
        let a = TimeOfDay.report(realTrades()).pOverall
        let b = TimeOfDay.report(realTrades()).pOverall
        XCTAssertEqual(a, b)
    }

    /// 真有差别时要认得出来:上午全赚、下午全亏。
    func testDetectsARealDifference() throws {
        let ts = (0..<15).map { at(10, $0 * 3, 300 + Double($0)) }
               + (0..<15).map { at(14, $0 * 3, -300 - Double($0)) }
        let p = try XCTUnwrap(TimeOfDay.report(ts).pOverall)
        XCTAssertLessThan(p, 0.01)
    }

    /// 精确概率本身:从 10 个里挑 3 个全落在某 5 个里 = C(5,3)/C(10,3) = 10/120。
    func testHypergeometric() {
        XCTAssertEqual(TimeOfDay.hypergeomAll(m: 5, N: 10, k: 3), 10.0 / 120.0, accuracy: 1e-12)
        XCTAssertEqual(TimeOfDay.hypergeomAll(m: 2, N: 10, k: 3), 0)
        XCTAssertEqual(TimeOfDay.hypergeomAll(m: 10, N: 10, k: 3), 1, accuracy: 1e-12)
    }

    func testRanksHandleTies() {
        XCTAssertEqual(TimeOfDay.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4])
    }
}

/// ★★ 浮点误差不许改变结论。
///   2026-10-03 用真实数据一跑:三笔「正好赚 $100」里一笔算出来是 100.000000000000227,
///   11:00 段的概率从 0.55% 变成 0.38%。测试没抓到,因为测试数据读自 CSV(已四舍五入)。
extension TimeOfDayTests {
    func testFloatNoiseDoesNotChangeTheVerdict() {
        let clean = TimeOfDay.report(realTradesWith(noise: 0))
        let noisy = TimeOfDay.report(realTradesWith(noise: 2.27e-13))
        XCTAssertEqual(clean.extremes.map(\.p), noisy.extremes.map(\.p),
                       "多出 0.0000000000002 美分,结论就变了 —— 比较之前必须按分取整")
        XCTAssertEqual(clean.pOverall, noisy.pOverall)
    }

    /// 把真实数据里某一笔 +$100(不在 11:00 段的那笔)换成带浮点尾巴的版本。
    private func realTradesWith(noise: Double) -> [Trade] {
        var hit = false
        return Self.real.map { r in
            var pnl = r.6
            if !hit, pnl == 100, !(r.1 == 11) { pnl += noise; hit = true }
            return tradeForNoiseTest(r.0, r.1, r.2, r.3, r.4, r.5, pnl)
        }
    }
    private func tradeForNoiseTest(_ od: String, _ oh: Int, _ om: Int, _ cd: String, _ ch: Int, _ cm: Int,
                                   _ pnl: Double) -> Trade {
        func d(_ day: String, _ h: Int, _ m: Int) -> Date {
            let p = day.split(separator: "-").compactMap { Int($0) }
            var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
            c.hour = h; c.minute = m; c.timeZone = TradingDay.exchangeTimeZone
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        let leg = Leg(kind: .equity)
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: d(od, oh, om), side: .buy, quantity: 1, price: 0),
            Fill(legID: leg.id, time: d(cd, ch, cm), side: .sell, quantity: 1, price: pnl)])
    }

    func testCents() {
        XCTAssertEqual(TimeOfDay.cents(100.000000000000227), 100)
        XCTAssertEqual(TimeOfDay.cents(99.99999999999997), 100)
        XCTAssertEqual(TimeOfDay.cents(-892.994), -892.99)
    }
}
