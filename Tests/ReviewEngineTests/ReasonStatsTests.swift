import XCTest
@testable import ReviewEngine

/// 按原因汇总 + 计划 R:R + 止损有没有被碰过。
/// ★ 用户 2026-09-02 的要求:「开单原因汇总整理,止损,出场原因」。
final class ReasonStatsTests: XCTestCase {

    private func t(entry: Double, exit: Double, reason: String?, exitReason: String?,
                   stop: Double? = nil, target: Double? = nil,
                   path: [PriceBar]? = nil, close: Double? = nil, day: Int = 6) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = day
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        var leg = Leg(kind: .option(right: .call, strike: 700,
                                    expiry: t0.addingTimeInterval(21600)))
        leg.path = path
        var tr = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: entry),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .sell,
                 quantity: 1, price: exit),
        ], finalUnderlying: close)
        tr.entryReason = reason
        tr.exitReason = exitReason
        tr.plannedStop = stop
        tr.plannedTarget = target
        return tr
    }

    func testGroupsByEntryReason() {
        let s = ReasonStats.compute([
            t(entry: 1, exit: 2, reason: "结构位", exitReason: "触及目标"),
            t(entry: 1, exit: 3, reason: "结构位", exitReason: "触及目标"),
            t(entry: 2, exit: 1, reason: "消息面", exitReason: "触及止损"),
        ])
        XCTAssertEqual(s.byEntryReason.count, 2)
        let top = s.byEntryReason[0]
        XCTAssertEqual(top.reason, "结构位")
        XCTAssertEqual(top.n, 2)
        XCTAssertEqual(top.wins, 2)
        XCTAssertEqual(top.totalPnL, 100 + 200, accuracy: 0.01)
        XCTAssertEqual(s.byEntryReason[1].reason, "消息面")
        XCTAssertEqual(s.byEntryReason[1].wins, 0)
    }

    func testGroupsByExitReason() {
        let s = ReasonStats.compute([
            t(entry: 1, exit: 2, reason: nil, exitReason: "触及目标"),
            t(entry: 1, exit: 2, reason: nil, exitReason: "提前手动平"),
            t(entry: 1, exit: 2, reason: nil, exitReason: "提前手动平"),
        ])
        XCTAssertEqual(s.byExitReason.first?.reason, "提前手动平")
        XCTAssertEqual(s.byExitReason.first?.n, 2)
    }

    func testTradesWithoutAReasonAreNotBucketedIntoAFakeGroup() {
        // ★ 没填原因就不该出现在任何一组里 —— 不许造一个「其他」把它们塞进去
        let s = ReasonStats.compute([
            t(entry: 1, exit: 2, reason: nil, exitReason: nil),
            t(entry: 1, exit: 2, reason: "  ", exitReason: ""),
        ])
        XCTAssertTrue(s.byEntryReason.isEmpty)
        XCTAssertTrue(s.byExitReason.isEmpty)
        XCTAssertEqual(s.closedCount, 2, "但它们仍然算在已平仓总数里")
    }

    // ── 止损 ────────────────────────────────────────────────────────

    func testCountsHowManyActuallyHadAStop() {
        let s = ReasonStats.compute([
            t(entry: 1, exit: 2, reason: nil, exitReason: nil, stop: 0.8),
            t(entry: 1, exit: 2, reason: nil, exitReason: nil),
        ])
        XCTAssertEqual(s.withStop, 1)
        XCTAssertEqual(s.closedCount, 2)
    }

    func testStopTouchedNeedsRealPath() {
        // 没路径 -> nil,**不猜**
        let noPath = ReasonStats.compute([
            t(entry: 1, exit: 2, reason: nil, exitReason: nil, stop: 0.8)])
        XCTAssertNil(noPath.stopTouched)
        XCTAssertEqual(noPath.stopCheckable, 0)
    }

    /// 持仓窗内的一根 K。★ 时间戳必须落在**入场→出场**之间,
    /// 否则切片后是空的 —— 那正是 `stopWasTouched` 现在的正确行为。
    private func barInWindow(day: Int = 6, offsetSec: Double = 120,
                             h: Double, l: Double) -> PriceBar {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = day
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        return PriceBar(t: t0.addingTimeInterval(offsetSec), h: h, l: l, c: (h + l) / 2)
    }

    func testStopNeverTouched() {
        // ★ 这就是用户 8 月那几笔想看的:止损到底有没有被检验过
        let bars = (0..<5).map {
            barInWindow(offsetSec: Double($0) * 100,
                        h: 1.5 + Double($0) * 0.1, l: 1.2 + Double($0) * 0.1)
        }
        let s = ReasonStats.compute([
            t(entry: 1.34, exit: 2.41, reason: nil, exitReason: nil,
              stop: 0.8, path: bars)])
        XCTAssertEqual(s.stopCheckable, 1)
        XCTAssertEqual(s.stopTouched, 0, "持仓内最低 1.2,止损 0.8 从未被碰到")
    }

    func testStopTouched() {
        let s = ReasonStats.compute([
            t(entry: 1.34, exit: 2.41, reason: nil, exitReason: nil,
              stop: 0.8, path: [barInWindow(h: 1.4, l: 0.7)])])
        XCTAssertEqual(s.stopTouched, 1)
    }

    func testBarsOutsideTheHoldingWindowDoNotCount() {
        // ★ 路径存到当天收盘,但**只有持仓期间**算数。
        //   这条直接盯住那个错了三次的窗口问题。
        let s = ReasonStats.compute([
            t(entry: 1.34, exit: 2.41, reason: nil, exitReason: nil,
              stop: 0.8, path: [barInWindow(offsetSec: 20_000, h: 0.3, l: 0.05)])])
        XCTAssertNil(s.stopTouched, "持仓窗内一根都没有 -> 判不了,而不是判成「碰到了」")
    }

    // ── 计划 R:R ────────────────────────────────────────────────────

    func testPlannedRR() {
        // 入场 2.0,止损 1.6,目标 3.0 -> 风险 0.4、回报 1.0 -> 2.5
        let tr = t(entry: 2.0, exit: 2.5, reason: nil, exitReason: nil,
                   stop: 1.6, target: 3.0)
        XCTAssertEqual(tr.plannedRR ?? .nan, 2.5, accuracy: 1e-9)
    }

    func testPlannedRRNilWhenIncomplete() {
        XCTAssertNil(t(entry: 2, exit: 3, reason: nil, exitReason: nil, stop: 1.6).plannedRR)
        XCTAssertNil(t(entry: 2, exit: 3, reason: nil, exitReason: nil, target: 3).plannedRR)
    }

    func testPlannedRRRefusesInvertedStop() {
        // 多头腿把止损填在入场上方 = 填错了,不该算出一个数
        XCTAssertNil(t(entry: 2, exit: 3, reason: nil, exitReason: nil,
                       stop: 2.5, target: 3).plannedRR)
    }

    func testMedianRR() {
        let s = ReasonStats.compute([
            t(entry: 2, exit: 3, reason: nil, exitReason: nil, stop: 1.6, target: 3.0),  // 2.5
            t(entry: 2, exit: 3, reason: nil, exitReason: nil, stop: 1.0, target: 3.0),  // 1.0
        ])
        XCTAssertEqual(s.medianPlannedRR ?? .nan, 1.75, accuracy: 1e-9)
    }

    func testSamplesExcluded() {
        var sample = t(entry: 1, exit: 2, reason: "结构位", exitReason: "触及目标")
        sample.isSample = true
        XCTAssertTrue(ReasonStats.compute([sample]).byEntryReason.isEmpty)
    }
}

/// ★★ 止损判定必须只看**持仓期间** —— 这是同一个窗口错误的第三次。
final class StopWindowTests: XCTestCase {

    /// 入场 1.34、止损 1.20、10 分钟后 2.41 出场;**出场之后**才跌到 0.03。
    private func trade(stop: Double) -> Trade {
        let t0 = ISO8601DateFormatter().date(from: "2026-08-06T14:30:00Z")!
        var leg = Leg(kind: .option(right: .call, strike: 717,
                                    expiry: t0.addingTimeInterval(20000)))
        leg.path = [
            PriceBar(t: t0,                         h: 1.45, l: 1.30, c: 1.34),  // 持仓中
            PriceBar(t: t0.addingTimeInterval(300), h: 1.80, l: 1.28, c: 1.75),  // 持仓中
            PriceBar(t: t0.addingTimeInterval(600), h: 2.50, l: 2.30, c: 2.41),  // 出场
            PriceBar(t: t0.addingTimeInterval(9000), h: 0.30, l: 0.03, c: 0.03), // ★ 走之后
        ]
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 3, price: 1.34),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .sell,
                 quantity: 3, price: 2.41),
        ], finalUnderlying: 715.56)
        t.plannedStop = stop
        return t
    }

    func testPriceCollapsingAfterYouExitIsNotYourStopBeingTested() {
        // 止损 1.20:持仓内最低 1.28,**没碰到**;走之后跌到 0.03,那与你无关
        XCTAssertEqual(trade(stop: 1.20).stopWasTouched(), false,
                       "★ 你出场之后的下跌不是「你的止损被检验」")
    }

    func testStopInsideHoldingWindowIsDetected() {
        // 止损 1.30:持仓内最低 1.28 击穿 -> 真的碰到了
        XCTAssertEqual(trade(stop: 1.30).stopWasTouched(), true)
    }

    func testTouchedButHeldIsCountedSeparately() {
        // ★ 碰到了止损却没按它出场,而且最后还赚钱 —— 这是纪律问题,不是「未经检验」
        let s = ReasonStats.compute([trade(stop: 1.30)])
        XCTAssertEqual(s.stopTouched, 1)
        XCTAssertEqual(s.stopTouchedButHeld, 1)
    }

    func testNotTouchedMeansNotCountedAsDisciplineProblem() {
        let s = ReasonStats.compute([trade(stop: 1.20)])
        XCTAssertEqual(s.stopTouched, 0)
        XCTAssertEqual(s.stopTouchedButHeld, 0)
    }
}
