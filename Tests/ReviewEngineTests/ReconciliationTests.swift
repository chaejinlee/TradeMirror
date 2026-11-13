import XCTest
@testable import ReviewEngine

/// 对账 + 没记进来的那些。
///
/// ★★ 起因是 2026-09-03 的一个事实:App 里 4 胜 0 负、100% 胜率、+$705,
///   而当天真实发生的那笔 **−$140 亏损正好就是导入失败的那一张**。
///   而失败之前**不留任何痕迹**。
///   <b>光看 App 内部的数,永远看不出自己漏了什么</b> ——
///   漏掉的按定义就不在里面。只能拿一个外部的数来对。
final class ReconciliationTests: XCTestCase {

    private func at(_ month: Int, _ day: Int, _ h: Int = 10) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = day
        c.hour = h; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func trade(_ month: Int, _ day: Int, sample: Bool = false) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: at(month, day, 16)))
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: at(month, day), side: .buy, quantity: 1, price: 1.0),
            Fill(legID: leg.id, time: at(month, day, 11), side: .sell, quantity: 1, price: 1.5),
        ])
        t.isSample = sample
        return t
    }

    // ── 归月:按**开仓日**,和券商月结单一个口径 ──────────────────────

    func testRecordedCountIsByEntryMonth() {
        let r = ReconciliationEngine.result(
            monthKey: "2026-09",
            trades: [trade(9, 1), trade(9, 30), trade(8, 31)],
            failures: [], records: [])
        XCTAssertEqual(r.recorded, 2, "8/31 那笔不算 9 月")
    }

    /// ★ 示例交易不算 —— 它不是你做的单,混进来对账就永远对不上。
    func testSampleTradesAreExcluded() {
        let r = ReconciliationEngine.result(
            monthKey: "2026-09",
            trades: [trade(9, 1), trade(9, 2, sample: true)],
            failures: [], records: [])
        XCTAssertEqual(r.recorded, 1)
    }

    // ── 差额:填了才算,不填就说算不了 ────────────────────────────────

    /// ★ 没填券商笔数时 `gap` 必须是 nil。**不猜** ——
    ///   猜一个 0 出来等于告诉用户「对上了」,而根本没对过。
    func testGapIsNilUntilYouEnterTheBrokerCount() {
        let r = ReconciliationEngine.result(monthKey: "2026-09", trades: [trade(9, 1)],
                                            failures: [], records: [])
        XCTAssertNil(r.gap)
        XCTAssertEqual(r.recorded, 1)
    }

    func testGapCountsMissingTrades() {
        let r = ReconciliationEngine.result(
            monthKey: "2026-09", trades: [trade(9, 1), trade(9, 2)],
            failures: [],
            records: [Reconciliation(monthKey: "2026-09", brokerTradeCount: 5)])
        XCTAssertEqual(r.gap, 3, "券商 5 笔、App 里 2 笔 ⇒ 差 3")
    }

    /// App 里比券商多 ⇒ 多半是重复导入,差额为负。
    func testNegativeGapMeansDuplicates() {
        let r = ReconciliationEngine.result(
            monthKey: "2026-09", trades: [trade(9, 1), trade(9, 2), trade(9, 3)],
            failures: [],
            records: [Reconciliation(monthKey: "2026-09", brokerTradeCount: 2)])
        XCTAssertEqual(r.gap, -1)
    }

    /// 差额里有多少能被「导入失败」解释掉 —— 上限是差额本身,不能超。
    func testExplainedByFailuresIsCappedByTheGap() {
        let fails = (1...5).map { ImportFailure(at: at(9, $0), reason: .ocrEmpty) }
        let r = ReconciliationEngine.result(
            monthKey: "2026-09", trades: [trade(9, 1)], failures: fails,
            records: [Reconciliation(monthKey: "2026-09", brokerTradeCount: 3)])
        XCTAssertEqual(r.gap, 2)
        XCTAssertEqual(r.importFailures, 5)
        XCTAssertEqual(r.explainedByFailures, 2, "解释不了比差额还多的笔数")
    }

    /// 差额为 0 时不该说「有 N 笔能解释」。
    func testNothingToExplainWhenItBalances() {
        let r = ReconciliationEngine.result(
            monthKey: "2026-09", trades: [trade(9, 1)],
            failures: [ImportFailure(at: at(9, 1), reason: .abandoned)],
            records: [Reconciliation(monthKey: "2026-09", brokerTradeCount: 1)])
        XCTAssertEqual(r.gap, 0)
        XCTAssertEqual(r.explainedByFailures, 0)
    }

    // ── 失败清单 ────────────────────────────────────────────────────

    func testFailuresAreCountedByExchangeMonth() {
        let fails = [ImportFailure(at: at(8, 31, 23), reason: .ocrEmpty),
                     ImportFailure(at: at(9, 1), reason: .unusable)]
        XCTAssertEqual(fails.count(inMonthOf: at(9, 15)), 1)
        XCTAssertEqual(fails.count(inMonthOf: at(8, 15)), 1)
    }

    /// ★ 只留前几行 —— 留着是为了认出是哪一张、以及照着加夹具,
    ///   不是为了把整张截图的文字都存下来。
    func testOnlyTheFirstFewLinesAreKept() {
        let f = ImportFailure(reason: .unusable,
                              lines: (1...20).map { "line \($0)" })
        XCTAssertEqual(f.lines.count, 6)
        XCTAssertEqual(f.lines.first, "line 1")
    }

    /// ★ 老存档没有这两个字段:必须照样读得出来(v8 栽过一次)。
    func testOldArchiveWithoutTheNewArraysStillDecodes() throws {
        let f = StoreFile(trades: [trade(9, 1)])
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(f)) as! [String: Any]
        json.removeValue(forKey: "importFailures")
        json.removeValue(forKey: "reconciliations")
        let back = try JSONDecoder().decode(
            StoreFile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(back.importFailures.isEmpty)
        XCTAssertTrue(back.reconciliations.isEmpty)
        XCTAssertEqual(back.trades.count, 1)
    }

    func testNewArraysSurviveRoundTrip() throws {
        let f = StoreFile(trades: [], importFailures: [ImportFailure(reason: .ocrEmpty)],
                          reconciliations: [Reconciliation(monthKey: "2026-09",
                                                           brokerTradeCount: 7)])
        let back = try JSONDecoder().decode(StoreFile.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back.importFailures.count, 1)
        XCTAssertEqual(back.reconciliations.first?.brokerTradeCount, 7)
    }
}
