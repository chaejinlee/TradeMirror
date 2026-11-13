import XCTest
@testable import ReviewEngine

/// 日 / 周 / 月 / 年战绩。
/// ★ 这一组测试守的全是**口径**问题 —— 数字本身好算,归到哪个周期才是容易错的地方。
final class PeriodStatsTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TradingDay.exchangeTimeZone
        return c
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
        c.timeZone = TradingDay.exchangeTimeZone
        return cal.date(from: c)!
    }

    /// 开仓时间 / 平仓时间可以跨天 —— 这正是要测的。
    private func trade(open: Date, close: Date?, entry: Double = 1.0,
                       exit: Double = 2.0, close_: Double? = nil) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700,
                                    expiry: at(2026, 9, 30, 16)))
        var fills = [Fill(legID: leg.id, time: open, side: .buy,
                          quantity: 1, price: entry, underlying: 700)]
        if let close {
            fills.append(Fill(legID: leg.id, time: close, side: .sell,
                              quantity: 1, price: exit, underlying: 705))
        }
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills,
                     finalUnderlying: close_)
    }

    // ── ① 归期用「兑现日」,不是开仓日 ────────────────────────────────

    func testBucketedByRealizationDayNotOpenDay() {
        // 8/31 开、9/2 平 -> 盈亏归 9/2
        let t = trade(open: at(2026, 8, 31, 15), close: at(2026, 9, 2, 10))
        let s = PeriodStats.compute([t], period: .day, now: at(2026, 9, 2, 12))
        XCTAssertEqual(s.current.key, "2026-09-02")
        XCTAssertEqual(s.current.n, 1, "★ 钱是 9/2 进来的,就归 9/2")
        XCTAssertEqual(s.current.pnl, 100, accuracy: 0.01)
        XCTAssertNil(s.buckets.first { $0.key == "2026-08-31" }?.n,
                     "8/31 不该出现在日战绩里")
    }

    func testRealizedAtIsTheLastClosingFill() {
        let t = trade(open: at(2026, 9, 1, 10), close: at(2026, 9, 2, 11, 30))
        XCTAssertEqual(t.realizedAt, at(2026, 9, 2, 11, 30))
    }

    func testOpenTradeHasNoRealizedAt() {
        XCTAssertNil(trade(open: at(2026, 9, 2), close: nil).realizedAt)
    }

    // ── ② 未平仓不进盈亏,但要报出来 ─────────────────────────────────

    func testOpenTradeCountedSeparatelyNotAsZeroPnL() {
        // ★ 今天开了一张还没平:显示「$0 · 0 笔」会被读成「今天没交易」
        let s = PeriodStats.compute([trade(open: at(2026, 9, 2, 10), close: nil)],
                                    period: .day, now: at(2026, 9, 2, 12))
        XCTAssertEqual(s.current.n, 0)
        XCTAssertEqual(s.current.pnl, 0)
        XCTAssertEqual(s.current.openCount, 1, "★ 必须单独报「有 1 张在手」")
    }

    func testOpenTradeGoesToItsOpenDay() {
        let s = PeriodStats.compute([trade(open: at(2026, 8, 31, 10), close: nil)],
                                    period: .day, now: at(2026, 9, 2))
        XCTAssertEqual(s.buckets.first { $0.key == "2026-08-31" }?.openCount, 1)
    }

    // ── ③ 周从**周一**开始 ─────────────────────────────────────────

    func testWeekStartsMonday() {
        // 2026-08-31 是周一,2026-09-06 是周日 -> 同一周
        let mon = trade(open: at(2026, 8, 31, 10), close: at(2026, 8, 31, 11))
        let sun = trade(open: at(2026, 9, 6, 10), close: at(2026, 9, 6, 11))
        let s = PeriodStats.compute([mon, sun], period: .week, now: at(2026, 9, 2))
        XCTAssertEqual(s.buckets.count, 1, "周一到周日是同一周:\(s.buckets.map(\.key))")
        XCTAssertEqual(s.buckets[0].n, 2)
    }

    func testSundayAndMondayAreDifferentWeeks() {
        // 8/30(周日)属于上一周,8/31(周一)属于新的一周
        let sun = trade(open: at(2026, 8, 30, 10), close: at(2026, 8, 30, 11))
        let mon = trade(open: at(2026, 8, 31, 10), close: at(2026, 8, 31, 11))
        let s = PeriodStats.compute([sun, mon], period: .week, now: at(2026, 9, 2))
        XCTAssertEqual(s.buckets.count, 2, "★ 周日和周一不能算一周")
    }

    // ── ④ 月 / 年 ─────────────────────────────────────────────────

    func testMonthAndYearBuckets() {
        let a = trade(open: at(2026, 8, 6, 10), close: at(2026, 8, 6, 11))
        let b = trade(open: at(2026, 9, 2, 10), close: at(2026, 9, 2, 11))
        XCTAssertEqual(PeriodStats.compute([a, b], period: .month,
                                           now: at(2026, 9, 2)).buckets.count, 2)
        XCTAssertEqual(PeriodStats.compute([a, b], period: .year,
                                           now: at(2026, 9, 2)).buckets.count, 1)
        XCTAssertEqual(PeriodStats.compute([a, b], period: .year,
                                           now: at(2026, 9, 2)).current.n, 2)
    }

    // ── ⑤ 时区 ────────────────────────────────────────────────────

    func testUsesExchangeTimeZoneNotDeviceTimeZone() {
        // 纽约 2026-09-02 09:35 = UTC 13:35。若按 UTC 或亚洲时区分桶,日期会跳。
        let t = trade(open: at(2026, 9, 2, 9, 35), close: at(2026, 9, 2, 9, 50))
        let s = PeriodStats.compute([t], period: .day, now: at(2026, 9, 2, 12))
        XCTAssertEqual(s.current.key, "2026-09-02")
        // 收盘后一点(15:59 ET)仍是同一天
        let late = trade(open: at(2026, 9, 2, 15, 55), close: at(2026, 9, 2, 15, 59))
        XCTAssertEqual(PeriodStats.compute([late], period: .day,
                                            now: at(2026, 9, 2, 20)).current.key,
                       "2026-09-02")
    }

    // ── ⑥ 当前周期即使为空也要存在 ───────────────────────────────────

    func testCurrentPeriodExistsEvenWithNoTrades() {
        let s = PeriodStats.compute([], period: .day, now: at(2026, 9, 2))
        XCTAssertEqual(s.current.key, "2026-09-02")
        XCTAssertEqual(s.current.n, 0)
        XCTAssertEqual(s.buckets.count, 1, "「今天还没交易」本身就是要显示的信息")
    }

    func testNewestBucketFirst()  {
        let a = trade(open: at(2026, 8, 6, 10), close: at(2026, 8, 6, 11))
        let b = trade(open: at(2026, 9, 1, 10), close: at(2026, 9, 1, 11))
        let s = PeriodStats.compute([a, b], period: .day, now: at(2026, 9, 2))
        XCTAssertEqual(s.buckets.map(\.key).first, "2026-09-02", "当前那格在最前")
        XCTAssertEqual(s.buckets.map(\.key).last, "2026-08-06")
    }

    // ── ⑦ 示例数据 & 反事实 ─────────────────────────────────────────

    func testSampleExcluded() {
        var s0 = trade(open: at(2026, 9, 2, 10), close: at(2026, 9, 2, 11))
        s0.isSample = true
        let s = PeriodStats.compute([s0], period: .day, now: at(2026, 9, 2))
        XCTAssertEqual(s.current.n, 0)
    }

    func testBestAlternativeExcludesThePeakOne() {
        // 「峰值出场」不可执行,不许当成「最好的替代方案」
        let t = trade(open: at(2026, 9, 2, 10), close: at(2026, 9, 2, 11),
                      entry: 1.0, exit: 2.0, close_: 760)     // 收盘远高 -> 拿到收盘会好得多
        let s = PeriodStats.compute([t], period: .day, now: at(2026, 9, 2))
        XCTAssertNotNil(s.current.bestAlternativeDelta)
        XCTAssertNotEqual(s.current.bestAlternativeLabel, "若在标的峰值处出场")
    }

    func testWinsCounted() {
        let win = trade(open: at(2026, 9, 2, 10), close: at(2026, 9, 2, 11),
                        entry: 1, exit: 2)
        let loss = trade(open: at(2026, 9, 2, 12), close: at(2026, 9, 2, 13),
                         entry: 2, exit: 1)
        let s = PeriodStats.compute([win, loss], period: .day, now: at(2026, 9, 2))
        XCTAssertEqual(s.current.n, 2)
        XCTAssertEqual(s.current.wins, 1)
        XCTAssertEqual(s.current.pnl, 0, accuracy: 0.01)
        XCTAssertEqual(s.current.winRate, 0.5, accuracy: 1e-9)
    }
}

/// ★★ 「当前周期是空的」不该把整张卡废掉。
/// 实测:用户数据全在 8 月,切到「月」时 9 月 0 笔 —— 大号数字显示「还没交易」,
/// 而他要的战绩被压成一根小条。
final class ScoreboardFallbackTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TradingDay.exchangeTimeZone
        return c
    }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        c.timeZone = TradingDay.exchangeTimeZone
        return cal.date(from: c)!
    }
    private func closed(_ open: Date, _ close: Date, pnl: Double = 100) -> Trade {
        let leg = Leg(kind: .equity)
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: open, side: .buy, quantity: 100, price: 10),
            Fill(legID: leg.id, time: close, side: .sell, quantity: 100,
                 price: 10 + pnl / 100),
        ])
    }

    func testFallsBackToTheMostRecentPeriodWithTrades() {
        // 8 月有交易,9 月没有 -> 大号数字该显示 8 月
        let t = closed(at(2026, 8, 6), at(2026, 8, 6, 11), pnl: 705)
        let s = PeriodStats.compute([t], period: .month, now: at(2026, 9, 2))
        XCTAssertEqual(s.current.n, 0, "当前月确实是 0 笔")
        XCTAssertEqual(s.displayed.n, 1, "★ 但大号数字要显示 8 月")
        XCTAssertEqual(s.displayed.pnl, 705, accuracy: 0.01)
        XCTAssertTrue(s.showingFallback, "★ 而且必须告诉用户换了一格")
    }

    func testNoFallbackWhenCurrentPeriodHasTrades() {
        let t = closed(at(2026, 9, 2), at(2026, 9, 2, 11))
        let s = PeriodStats.compute([t], period: .day, now: at(2026, 9, 2, 12))
        XCTAssertFalse(s.showingFallback)
        XCTAssertEqual(s.displayed.key, s.current.key)
    }

    func testOpenPositionCountsAsActivityForFallback() {
        // 今天开了一张还没平 -> 那也是「今天有活动」,不该回退到别的日子
        let leg = Leg(kind: .equity)
        let open = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: at(2026, 9, 2), side: .buy,
                 quantity: 100, price: 10)])
        let old = closed(at(2026, 8, 6), at(2026, 8, 6, 11))
        let s = PeriodStats.compute([open, old], period: .day, now: at(2026, 9, 2, 12))
        XCTAssertFalse(s.showingFallback)
        XCTAssertEqual(s.displayed.openCount, 1)
    }

    func testStripExcludesTheDisplayedBucket() {
        let a = closed(at(2026, 8, 3), at(2026, 8, 3, 11))
        let b = closed(at(2026, 8, 6), at(2026, 8, 6, 11))
        let s = PeriodStats.compute([a, b], period: .day, now: at(2026, 9, 2))
        XCTAssertTrue(s.showingFallback)
        XCTAssertFalse(s.strip.contains { $0.key == s.displayed.key },
                       "★ 大号那一格不该在小条里再画一遍")
        XCTAssertEqual(s.strip.count, 1)
    }

    func testStripSkipsEmptyPeriods() {
        // 空周期画成 0 高的柱子只是噪音
        let t = closed(at(2026, 8, 6), at(2026, 8, 6, 11))
        let s = PeriodStats.compute([t], period: .day, now: at(2026, 9, 2))
        XCTAssertTrue(s.strip.allSatisfy { $0.n > 0 || $0.openCount > 0 })
    }

    func testEverythingEmptyStillWorks() {
        let s = PeriodStats.compute([], period: .month, now: at(2026, 9, 2))
        XCTAssertEqual(s.displayed.key, s.current.key)
        XCTAssertFalse(s.showingFallback)
        XCTAssertTrue(s.strip.isEmpty)
    }
}
