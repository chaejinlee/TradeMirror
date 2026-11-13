import XCTest
@testable import ReviewEngine

/// 批量导入。用户原话:「不该一遍又一遍查找然后输入」——
/// 一天 5 笔 = 10 张截图,原来要走 10 遍流程。
final class BatchImporterTests: XCTestCase {

    /// ★ 用户真实的那两张:买入 + 卖出 → 必须归成**一笔**,不是两笔。
    func testBuyAndSellScreenshotsBecomeOneTrade() {
        let b = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)
        let s = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        let d = BatchImporter.group([b, s], existing: [])
        XCTAssertEqual(d.count, 1, "两张截图 = 一笔交易,不是两笔")
        XCTAssertEqual(d[0].parts.count, 2)
        XCTAssertNil(d[0].mergeInto, "都是新的,不该并进已有交易")
        XCTAssertTrue(d[0].reason.contains("2 张截图"))
    }

    /// 顺序打乱也要对(用户在相册里多选时顺序不一定)。
    func testOrderIndependent() {
        let b = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)
        let s = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        XCTAssertEqual(BatchImporter.group([s, b], existing: []).count, 1)
    }

    /// 不同行权价 = 不同合约,不许并。
    func testDifferentStrikesStaySeparate() {
        let b = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)          // 708
        var other = WealthsimpleRealTests.sellLines
        other[1] = "QQQ Sep 1 $715 Call"
        let s = ScreenshotParser.parse(lines: other)
        XCTAssertEqual(BatchImporter.group([b, s], existing: []).count, 2)
    }

    /// 同一合约、买入两次再一次卖出 —— 那是**一笔带加仓的交易**,不是两笔。
    /// (第一版我把这个用例的意图写反了,以为该拆成两笔。)
    func testTwoBuysThenSellIsOneTradeWithAnAdd() {
        let b = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)
        let s = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        let d = BatchImporter.group([b, b, s], existing: [])
        XCTAssertEqual(d.count, 1, "买、买、卖 = 一笔带加仓")
        XCTAssertEqual(d.first?.parts.count, 3)
    }

    /// ★ 配平之后再来的开仓,必须另起一笔。
    func testFlatGroupDoesNotAbsorbLaterEntry() {
        let b = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)      // 10:13
        let s = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)     // 10:35
        var later = WealthsimpleRealTests.buyLines
        later = later.map { $0.replacingOccurrences(of: "10:13 am", with: "11:20 am") }
        let b2 = ScreenshotParser.parse(lines: later)                              // 11:20
        XCTAssertEqual(b2.time?.value.hour, 11, "第三张的时间要真的更晚")

        let d = BatchImporter.group([b, s, b2], existing: [])
        XCTAssertEqual(d.count, 2, "前两张配平后,11:20 那张应该另起一笔")
        XCTAssertEqual(d.first?.parts.count, 2)
        XCTAssertEqual(d.last?.parts.count, 1)
    }

    /// App 里已有未平的同合约仓位 → 优先并进去。
    func testMergesIntoExistingOpenTrade() {
        let b = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 1
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let e = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: e))
        var t0 = c; t0.hour = 10; t0.minute = 13
        let open = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Calendar(identifier: .gregorian).date(from: t0)!,
                 side: .buy, quantity: b.quantity!.value, price: b.price!.value)])

        let s = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        let d = BatchImporter.group([s], existing: [open])
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].mergeInto?.id, open.id, "★ 该并进已有的未平仓位")
    }
}

/// 每日收盘价簿:填一次,当天该标的全部交易共用。
final class DailyCloseTests: XCTestCase {

    private func trade(day: Int, symbol: String = "QQQ") -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        let d = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .equity)
        return Trade(symbol: symbol, strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: d, side: .buy,  quantity: 10, price: 100),
            Fill(legID: leg.id, time: d.addingTimeInterval(3600), side: .sell,
                 quantity: 10, price: 105)])
    }

    /// ★ 核心:填一次,当天同标的的**每一笔**都用得上。
    func testOneEntryCoversAllSameDayTrades() {
        var book = DailyCloseBook()
        let a = trade(day: 1), b = trade(day: 1), c = trade(day: 2)
        book.set(707.66, for: a)
        XCTAssertEqual(a.effectiveFinalUnderlying(book), 707.66)
        XCTAssertEqual(b.effectiveFinalUnderlying(book), 707.66, "★ 同一天同标的,不用再填一遍")
        XCTAssertNil(c.effectiveFinalUnderlying(book), "另一天不该被套用")
    }

    /// 不同标的互不影响。
    func testDifferentSymbolsIsolated() {
        var book = DailyCloseBook()
        let q = trade(day: 1, symbol: "QQQ"), s = trade(day: 1, symbol: "SPY")
        book.set(707.66, for: q)
        XCTAssertNil(s.effectiveFinalUnderlying(book))
    }

    /// 本笔自己填过的优先于当天公共价。
    func testPerTradeValueWins() {
        var book = DailyCloseBook(); var t = trade(day: 1)
        book.set(707.66, for: t)
        t.finalUnderlying = 999
        XCTAssertEqual(t.effectiveFinalUnderlying(book), 999)
    }

    /// 汇总要用得上公共收盘价 —— 否则「填一次」这个机制在分析页就不生效。
    func testStatsUseSharedClose() {
        var book = DailyCloseBook()
        let a = trade(day: 1), b = trade(day: 1)
        book.set(107.0, for: a)
        XCTAssertEqual(PortfolioStats.compute([a, b], closes: book).nWithCounterfactuals, 2)
        XCTAssertEqual(PortfolioStats.compute([a, b]).nWithCounterfactuals, 0, "不传价簿就都算不出")
    }
}
