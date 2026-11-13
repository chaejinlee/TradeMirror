import XCTest
@testable import ReviewEngine

/// 开仓/出场**时刻**。用户 2026-09-03:「订单里面没显示具体开单时间」。
///
/// ★★ 一旦要显示时间,时区就从「显示问题」变成「正确性问题」:
///   同一笔 10:47 ET 的成交,按多伦多时区显示还是 10:47,
///   按北京时区显示就是**次日 22:47** —— 日期都变了。
///   全 App 的归日、当天收盘价共用、周期分桶都按交易所时区,
///   显示也必须按交易所时区,否则<b>屏幕上的时间和统计用的时间不是一回事</b>。
final class ClockTests: XCTestCase {

    private func at(_ h: Int, _ m: Int, day: Int = 2, month: Int = 9) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = day
        c.hour = h; c.minute = m; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func leg() -> Leg {
        Leg(kind: .option(right: .call, strike: 708, expiry: at(16, 0)))
    }

    func testClockIsExchangeTimeNotDeviceTime() {
        XCTAssertEqual(TradingDay.clock(of: at(10, 47)), "10:47")
        XCTAssertEqual(TradingDay.clock(of: at(9, 5)), "09:05")
        XCTAssertEqual(TradingDay.clock(of: at(15, 59)), "15:59")
    }

    /// ★ 关键一条:设备时区换了,显示的时刻**不许变**。
    ///   `TradingDay.clock` 用的是自己的日历(固定纽约),不是 `.current`。
    func testClockIgnoresDeviceTimeZone() {
        let t = at(10, 47)
        // 用北京时区手动算一遍 —— 那是 22:47(次日),说明「按设备时区」会算错
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let bj = beijing.dateComponents([.hour, .minute], from: t)
        XCTAssertEqual(bj.hour, 22, "前提校验:同一时刻在北京是 22 点")
        // 而我们显示的必须还是交易所时区的 10:47
        XCTAssertEqual(TradingDay.clock(of: t), "10:47")
    }

    func testEntryAndExitClockOnASimpleTrade() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(10, 30), side: .buy,  quantity: 2, price: 2.17),
            Fill(legID: l.id, time: at(10, 47), side: .buy,  quantity: 1, price: 1.57),
            Fill(legID: l.id, time: at(11, 2),  side: .sell, quantity: 3, price: 2.51),
        ])
        XCTAssertEqual(t.entryClock, "10:30", "开仓时刻 = 首笔**开仓**成交")
        XCTAssertEqual(t.exitClock, "11:02", "出场时刻 = 末笔**平仓**成交")
    }

    /// ★ 做空:首笔是**卖出**。拿「首笔买入」当开仓会把平仓时刻当成开仓时刻。
    func testShortTradeEntryIsTheSellFill() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(9, 45), side: .sell, quantity: 1, price: 3.00),
            Fill(legID: l.id, time: at(14, 20), side: .buy, quantity: 1, price: 1.20),
        ])
        XCTAssertEqual(t.entryClock, "09:45")
        XCTAssertEqual(t.exitClock, "14:20")
    }

    /// 未平仓**不给**出场时刻 —— 和 `displayablePnL` 同一个规矩:没发生的事不显示。
    func testOpenTradeHasNoExitClock() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(10, 30), side: .buy, quantity: 2, price: 2.17),
            Fill(legID: l.id, time: at(11, 0),  side: .sell, quantity: 1, price: 2.40),
        ])
        XCTAssertEqual(t.entryClock, "10:30")
        XCTAssertNil(t.exitClock, "还剩 1 张没平,不该显示出场时刻")
    }

    /// 多腿:开仓时刻取**所有腿里最早的那一笔开仓**。
    func testMultiLegTakesEarliestOpeningFill() {
        let a = Leg(kind: .option(right: .call, strike: 700, expiry: at(16, 0)))
        let b = Leg(kind: .option(right: .call, strike: 710, expiry: at(16, 0)))
        let t = Trade(symbol: "QQQ", strategy: .verticalSpread, legs: [a, b], fills: [
            Fill(legID: b.id, time: at(9, 40), side: .sell, quantity: 2, price: 2.00),
            Fill(legID: a.id, time: at(9, 42), side: .buy,  quantity: 2, price: 5.00),
            Fill(legID: a.id, time: at(14, 0), side: .sell, quantity: 2, price: 6.00),
            Fill(legID: b.id, time: at(14, 1), side: .buy,  quantity: 2, price: 2.50),
        ])
        XCTAssertEqual(t.entryClock, "09:40")
        XCTAssertEqual(t.exitClock, "14:01")
    }

    /// 没有成交就什么都不给,不返回「00:00」这种看起来像真数据的东西。
    func testNoFillsGivesNothing() {
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg()], fills: [])
        XCTAssertNil(t.entryClock)
        XCTAssertNil(t.exitClock)
    }

    // ── 不知道就说不知道 ────────────────────────────────────────────

    /// ★★ 用户 2026-09-03 的回归测试:
    ///   「今天我添加的几笔全都是 11 点的时间点,但实际上不是」。
    ///   录入页的默认时刻是个**占位值**;显示出来它就成了一条假记录。
    ///   ⇒ 标了 `timeIsEstimated` 的,时刻一律**不给**。
    func testEstimatedTimeIsNotShown() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(11, 0), side: .buy, quantity: 1, price: 2.00,
                 timeIsEstimated: true),
            Fill(legID: l.id, time: at(11, 0), side: .sell, quantity: 1, price: 3.00,
                 timeIsEstimated: true),
        ])
        XCTAssertNil(t.entryClock, "默认值不是成交时刻,不许显示")
        XCTAssertNil(t.exitClock)
        XCTAssertTrue(t.hasEstimatedTimes)
        // ★ 但盈亏、归日这些**照算不误** —— 时间本身还在,只是不当成事实展示
        XCTAssertEqual(t.displayablePnL ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(t.tradingDayKey, "2026-09-02")
    }

    /// 一半估一半真:真的那笔照显示,估的那笔不显示。
    func testMixedEstimatedAndRealTimes() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(10, 30), side: .buy, quantity: 1, price: 2.00),
            Fill(legID: l.id, time: at(11, 0), side: .sell, quantity: 1, price: 3.00,
                 timeIsEstimated: true),
        ])
        XCTAssertEqual(t.entryClock, "10:30")
        XCTAssertNil(t.exitClock, "出场那笔是估的 ⇒ 不给")
        XCTAssertTrue(t.hasEstimatedTimes)
    }

    /// 老存档(v3.2 之前)没有这个标记 —— 全是 11:00 时给个**提示**,不改数据。
    func testLegacyDefaultTimeIsFlaggedButNotRewritten() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(11, 0), side: .buy, quantity: 1, price: 2.00),
            Fill(legID: l.id, time: at(11, 0), side: .sell, quantity: 1, price: 3.00),
        ])
        XCTAssertTrue(t.looksLikeLegacyDefaultTime)
        XCTAssertFalse(t.hasEstimatedTimes, "只提示,**不替用户改数据**")
        XCTAssertEqual(t.entryClock, "11:00", "没有证据说它是假的 ⇒ 照显示")
        XCTAssertTrue(Sanity.check(t).contains { $0.code == "legacy_default_time" })
    }

    /// 只要有一笔不是 11:00,就不是「默认值」那种情况 —— 别乱提示。
    func testRealTradesAtElevenAreNotFlaggedWhenOthersDiffer() {
        let l = leg()
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [l], fills: [
            Fill(legID: l.id, time: at(11, 0), side: .buy, quantity: 1, price: 2.00),
            Fill(legID: l.id, time: at(13, 22), side: .sell, quantity: 1, price: 3.00),
        ])
        XCTAssertFalse(t.looksLikeLegacyDefaultTime)
        XCTAssertFalse(Sanity.check(t).contains { $0.code == "legacy_default_time" })
    }

    /// ★ 旧存档没有 `timeIsEstimated` 字段:必须照样读得出来,而且默认 false。
    ///   (合成的 Codable 遇到缺字段会**抛**,那会让整份存档读不出来 ——
    ///    v8 加 `trailingStopPct` 时已经栽过一次。)
    func testFillDecodesWithoutTheNewFlag() throws {
        let l = leg()
        let f = Fill(legID: l.id, time: at(10, 30), side: .buy, quantity: 1, price: 2.00)
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(f)) as! [String: Any]
        json.removeValue(forKey: "timeIsEstimated")
        let back = try JSONDecoder().decode(
            Fill.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(back.timeIsEstimated)
        XCTAssertEqual(back.quantity, 1)
        XCTAssertEqual(back.price, 2.00)
    }

    func testEstimatedFlagSurvivesRoundTrip() throws {
        let l = leg()
        let f = Fill(legID: l.id, time: at(11, 0), side: .buy, quantity: 1, price: 2.00,
                     timeIsEstimated: true)
        let back = try JSONDecoder().decode(Fill.self, from: JSONEncoder().encode(f))
        XCTAssertTrue(back.timeIsEstimated)
    }
}
