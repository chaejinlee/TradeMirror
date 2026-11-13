import XCTest
@testable import ReviewEngine

/// 交易列表按天分组。
final class DayGroupsTests: XCTestCase {

    private func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
        c.hour = h; c.minute = mi; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private func closed(_ pnl: Double, open: Date, close: Date, sample: Bool = false) -> Trade {
        let leg = Leg(kind: .equity)
        var t = Trade(symbol: "X", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: open, side: .buy, quantity: 100, price: 10),
            Fill(legID: leg.id, time: close, side: .sell, quantity: 100, price: 10 + pnl / 100)])
        t.isSample = sample
        return t
    }
    private func openPos(_ at: Date) -> Trade {
        let leg = Leg(kind: .equity)
        return Trade(symbol: "BEX", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: at, side: .buy, quantity: 467, price: 24.97)])
    }

    /// ★★ 跨夜的那笔(9/22 开、9/23 平)归 **9/23** —— 和热力图同一天。
    ///   这正是用户那笔 BEX 来回:格子上 +42 在 9/23,列表也必须排在 9/23。
    func testOvernightTradeLandsOnTheDayItWasClosed() {
        let g = DayGroups.group([closed(41.69, open: at(9, 22, 15, 20), close: at(9, 23, 10, 18))])
        XCTAssertEqual(g.map(\.key), ["2026-09-23"])
    }

    /// 未平仓按**开仓日**。
    func testOpenPositionLandsOnItsOpeningDay() {
        let g = DayGroups.group([openPos(at(8, 5, 15, 48))])
        XCTAssertEqual(g.map(\.key), ["2026-08-05"])
        XCTAssertEqual(g[0].openCount, 1)
        XCTAssertEqual(g[0].realized, 0, "未平仓不算盈亏")
    }

    /// ★★ 分组和热力图**逐日一致** —— 同一批交易,两边归出来的日子必须一样。
    func testAgreesWithTheHeatmapDayByDay() {
        let ts = [closed(261, open: at(8, 3, 9, 53), close: at(8, 3, 10, 29)),
                  closed(-893, open: at(9, 4, 10, 14), close: at(9, 4, 13, 31)),
                  closed(41.69, open: at(9, 22, 15, 20), close: at(9, 23, 10, 18)),
                  openPos(at(8, 5, 15, 48))]
        let fromGroups = Set(DayGroups.group(ts).map(\.key))
        // ★ PeriodStats 永远带着「今天」那一格(哪怕 0 笔)—— 只比真有交易的日子
        let fromStats = Set(PeriodStats.compute(ts, period: .day).buckets
            .filter { $0.n > 0 || $0.openCount > 0 }.map(\.key))
        XCTAssertEqual(fromGroups, fromStats, "列表和热力图把交易归到了不同的日子")
    }

    /// 新的一天在前,一天之内新的在前。
    func testNewestFirst() {
        let g = DayGroups.group([closed(1, open: at(9, 3, 11), close: at(9, 3, 11, 30)),
                                 closed(2, open: at(9, 15, 10), close: at(9, 15, 10, 30)),
                                 closed(3, open: at(9, 3, 14), close: at(9, 3, 14, 30))])
        XCTAssertEqual(g.map(\.key), ["2026-09-15", "2026-09-03"])
        XCTAssertEqual(g[1].trades.map { Int(($0.displayablePnL ?? 0).rounded()) }, [3, 1])
    }

    /// 组头的合计 = 当天兑现盈亏之和;示例数据不算。
    func testDailyTotalExcludesSamples() {
        let g = DayGroups.group([closed(100, open: at(9, 3, 10), close: at(9, 3, 11)),
                                 closed(-40, open: at(9, 3, 12), close: at(9, 3, 13)),
                                 closed(999, open: at(9, 3, 14), close: at(9, 3, 15), sample: true)])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].realized, 60, accuracy: 1e-6)
        XCTAssertEqual(g[0].closedCount, 2)
        XCTAssertEqual(g[0].trades.count, 3, "示例照样列出来,只是不进合计")
    }

    /// ★ 守恒:分组不许丢交易。
    func testNothingIsLost() {
        let ts = (1...20).map { i in closed(Double(i), open: at(9, i % 12 + 1, 10), close: at(9, i % 12 + 1, 11)) }
            + [openPos(at(8, 5, 15))]
        XCTAssertEqual(DayGroups.group(ts).reduce(0) { $0 + $1.trades.count }, ts.count)
    }
}
