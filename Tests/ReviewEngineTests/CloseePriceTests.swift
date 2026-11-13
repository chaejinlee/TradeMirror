import XCTest
@testable import ReviewEngine

/// ★★ 用户 2026-09-01 的真实交易与真实反馈:
/// 「这个是末日期权,我这张 708 的 call 收盘的时候实际上只有 0.25」。
///
/// 他指出的是一个**我们答错了题**的地方:
/// 「若持有到收盘」= 收盘时卖掉 → 拿**市场价**;
/// 「若持有到到期」= 放到归零 → 拿**内在价值**。
/// 我们一直算后者,标签却写着前者。<b>对 0DTE 这两个数差的就是全部。</b>
final class ClosePriceTests: XCTestCase {

    /// 真实数据:QQQ 2026-09-01 $708 Call,买 3 @ 1.34(10:13),卖 3 @ 2.41(10:35)。
    /// QQQ 当日 收 707.64 / 高 712.30(Yahoo 实测)。
    private func realTrade(userClose: Double? = nil) -> Trade {
        let expiry = ISO8601DateFormatter().date(from: "2026-09-01T20:00:00Z")!
        var leg = Leg(kind: .option(right: .call, strike: 708, expiry: expiry))
        leg.userClosePrice = userClose
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        let t1 = ISO8601DateFormatter().date(from: "2026-09-01T14:35:00Z")!
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy,  quantity: 3, price: 1.34, underlying: 707.73),
            Fill(legID: leg.id, time: t1, side: .sell, quantity: 3, price: 2.41, underlying: 709.80),
        ], peakUnderlying: 712.30, finalUnderlying: 707.64)
    }

    func testActualPnLMatchesReality() {
        // (2.41 − 1.34) × 3 × 100 = 321
        XCTAssertEqual(realTrade().realizedPnL, 321, accuracy: 1e-9)
    }

    func testWithoutUserClosePriceWeAnswerTheExpiryQuestion() {
        let cf = CounterfactualEngine.holdToClose(trade: realTrade(), finalUnderlying: 707.64)
        // 707.64 < 708 ⇒ 内在价值 0 ⇒ 开仓的 402 全亏
        XCTAssertEqual(cf.alternativePnL, -402, accuracy: 1e-9)
        XCTAssertTrue(cf.note?.contains("放到到期") ?? false,
                      "★ 必须说清这算的是「放到到期」,不是「收盘卖掉」:\(cf.note ?? "nil")")
    }

    func testUserSuppliedClosePriceIsUsedAsFact() {
        // 用户说的真实收盘价 0.25
        let cf = CounterfactualEngine.holdToClose(trade: realTrade(userClose: 0.25),
                                                  finalUnderlying: 707.64)
        // −402 + 0.25 × 3 × 100 = −327
        XCTAssertEqual(cf.alternativePnL, -327, accuracy: 1e-9)
        XCTAssertTrue(cf.note?.contains("你填的") ?? false, "要标明这个数是用户填的")
    }

    func testTheGapIsSeventyFiveDollars() {
        // ★ 这就是「模型」和「事实」之间的差:0.25 × 3 × 100 = 75
        let modelled = CounterfactualEngine.holdToClose(trade: realTrade(),
                                                        finalUnderlying: 707.64).alternativePnL
        let actual = CounterfactualEngine.holdToClose(trade: realTrade(userClose: 0.25),
                                                      finalUnderlying: 707.64).alternativePnL
        XCTAssertEqual(actual - modelled, 75, accuracy: 1e-9,
                       "末日权那几分钱时间价值,在 3 张上就是 $75 —— 占这笔盈利的 23%")
    }

    func testVerdictStillSaysUserWasBetterEitherWay() {
        // 两种算法下用户都赢了 —— 但赢多少差了 $75,而这个 App 卖的就是那个数
        for uc in [nil, 0.25] as [Double?] {
            let cf = CounterfactualEngine.holdToClose(trade: realTrade(userClose: uc),
                                                      finalUnderlying: 707.64)
            XCTAssertEqual(cf.verdict, .youWereBetter)
        }
    }

    func testUserClosePriceSurvivesRoundTrip() throws {
        let store = TradeStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-\(UUID().uuidString).json"))
        try store.save([realTrade(userClose: 0.25)])
        XCTAssertEqual(try store.load().first?.legs.first?.userClosePrice, 0.25)
    }

    func testOldFileWithoutTheFieldStillLoads() throws {
        // v8 存档没有这个字段 —— 必须当 nil 读进来,不能整份失败
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("v8-\(UUID().uuidString).json")
        let leg = UUID(), fill = UUID(), trade = UUID()
        let json = """
        {"schemaVersion":8,"trades":[{"id":"\(trade.uuidString)","symbol":"QQQ",
        "strategy":"单腿","legs":[{"id":"\(leg.uuidString)","kind":{"option":
        {"expiry":"2026-09-01T20:00:00Z","right":"call","strike":708}}}],
        "fills":[{"id":"\(fill.uuidString)","legID":"\(leg.uuidString)","price":1.34,
        "quantity":3,"side":"buy","time":"2026-09-01T14:13:00Z"}]}]}
        """
        try Data(json.utf8).write(to: url)
        let loaded = try TradeStore(url: url).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded.first?.legs.first?.userClosePrice)
    }
}
