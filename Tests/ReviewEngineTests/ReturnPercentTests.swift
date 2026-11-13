import XCTest
@testable import ReviewEngine

/// 每一笔的**收益率**。用户 2026-09-03:「添加每笔订单盈利百分比」。
///
/// ★★ 这个数最容易错的地方不是算式,是**分母**。
///   「$50 赚 $50 = 100%」和「押 $2,000 保证金赚 $50 = 2.5%」差 40 倍,
///   而两者的分子一模一样。所以这里每条测试测的都是分母。
final class ReturnPercentTests: XCTestCase {

    private var t0: Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 2
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func option(_ strike: Double) -> Leg {
        Leg(kind: .option(right: .call, strike: strike,
                          expiry: t0.addingTimeInterval(21600)))
    }

    // ── 借记开仓:分母 = 真正付出去的钱 ──────────────────────────────

    func testLongOptionReturnIsPnLOverNetDebit() {
        let leg = option(708)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy,  quantity: 2, price: 1.00),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600),
                 side: .sell, quantity: 2, price: 1.50),
        ])
        // 付 2×1.00×100 = $200,收 2×1.50×100 = $300 ⇒ 赚 $100 = +50%
        XCTAssertEqual(t.netDebit, 200, accuracy: 1e-6)
        XCTAssertEqual(t.displayablePnL ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(t.returnOnDebit ?? 0, 0.5, accuracy: 1e-9)
    }

    func testLossIsNegative() {
        let leg = option(708)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy,  quantity: 1, price: 2.00),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600),
                 side: .sell, quantity: 1, price: 0.50),
        ])
        XCTAssertEqual(t.returnOnDebit ?? 0, -0.75, accuracy: 1e-9)
    }

    /// 加仓:分母是**两次一共付出去多少**,不是首仓价。
    func testAddOnGoesIntoTheDenominator() {
        let leg = option(717)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 2, price: 2.17),
            Fill(legID: leg.id, time: t0.addingTimeInterval(1020),
                 side: .buy, quantity: 1, price: 1.57),
            Fill(legID: leg.id, time: t0.addingTimeInterval(1920),
                 side: .sell, quantity: 3, price: 2.51),
        ])
        // 付 (2×2.17 + 1×1.57)×100 = $591;收 3×2.51×100 = $753 ⇒ +$162
        XCTAssertEqual(t.netDebit, 591, accuracy: 1e-6)
        XCTAssertEqual(t.displayablePnL ?? 0, 162, accuracy: 1e-6)
        XCTAssertEqual(t.returnOnDebit ?? 0, 162.0 / 591.0, accuracy: 1e-9)
    }

    // ── 说不了就说不了 ──────────────────────────────────────────────

    /// ★★ 贷记开仓(先收钱)**必须返回 nil**。
    ///   收到的权利金不是本金;真正的分母是占用的保证金或最大风险,
    ///   而 App 拿不到这个数。<b>宁可不给,也不给一个分母不对的百分比。</b>
    func testCreditOpenHasNoReturnPercent() {
        let leg = option(720)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .sell, quantity: 1, price: 2.00),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600),
                 side: .buy,  quantity: 1, price: 0.50),
        ])
        XCTAssertEqual(t.displayablePnL ?? 0, 150, accuracy: 1e-6)   // 盈亏照算
        XCTAssertEqual(t.netDebit, 0, accuracy: 1e-9)
        XCTAssertNil(t.returnOnDebit, "贷记开仓没有「净投入」这个分母,不许硬算")
    }

    /// 未平仓返回 nil —— 和 `displayablePnL` 同一个规矩:持仓成本不是亏损。
    func testOpenPositionHasNoReturnPercent() {
        let leg = option(708)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: 1.00),
        ])
        XCTAssertNil(t.returnOnDebit)
    }

    /// 借记价差:分母是**净**借记(买腿付的减去卖腿收的),不是买腿的钱。
    func testDebitSpreadUsesNetNotGross() {
        let long = option(700), short = option(710)
        let t = Trade(symbol: "QQQ", strategy: .verticalSpread, legs: [long, short], fills: [
            Fill(legID: long.id,  time: t0, side: .buy,  quantity: 2, price: 5.00),
            Fill(legID: short.id, time: t0, side: .sell, quantity: 2, price: 2.00),
            Fill(legID: long.id,  time: t0.addingTimeInterval(14400),
                 side: .sell, quantity: 2, price: 6.00),
            Fill(legID: short.id, time: t0.addingTimeInterval(14400),
                 side: .buy,  quantity: 2, price: 2.50),
        ])
        // 净付 (5.00−2.00)×2×100 = $600;平仓净收 (6.00−2.50)×2×100 = $700 ⇒ +$100
        XCTAssertEqual(t.netDebit, 600, accuracy: 1e-6)
        XCTAssertEqual(t.returnOnDebit ?? 0, 100.0 / 600.0, accuracy: 1e-9)
    }

    // ── 事后补填的原因:标记要能存下来 ────────────────────────────────

    /// ★ 加字段炸旧存档这事栽过一次(v8 的 `trailingStopPct`)。
    ///   这条测的是**旧存档没有新字段照样读得出来**,而且不会被当成 true。
    func testOldArchiveWithoutTheNewFlagStillDecodes() throws {
        let leg = option(708)
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: 1.00),
        ])
        t.entryReason = "结构位"
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(t)) as! [String: Any]
        json.removeValue(forKey: "reasonsRecordedAfterOutcome")
        let back = try JSONDecoder().decode(
            Trade.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.entryReason, "结构位")
        XCTAssertFalse(back.reasonsRecordedAfterOutcome)
    }

    func testAfterOutcomeFlagSurvivesRoundTrip() throws {
        let leg = option(708)
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy,  quantity: 1, price: 1.00),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600),
                 side: .sell, quantity: 1, price: 1.20),
        ])
        t.entryReason = "结构位"; t.exitReason = "触及目标"
        t.reasonsRecordedAfterOutcome = true
        let back = try JSONDecoder().decode(Trade.self, from: JSONEncoder().encode(t))
        XCTAssertTrue(back.reasonsRecordedAfterOutcome)
        XCTAssertEqual(back.exitReason, "触及目标")
    }
}
