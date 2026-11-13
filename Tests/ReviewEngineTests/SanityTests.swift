import XCTest
@testable import ReviewEngine

/// ★★ 这一组测试来自**第一份一手证据**:用户 2026-09-01 导出的真实备份里,
///    一笔 QQQ 期权 `strike = 402`,而标的 707.73、权利金 1.34 ——
///    402 恰好 = 3 × 1.34 × 100,**总金额被当成了行权价**。
final class SanityTests: XCTestCase {

    private func optionTrade(strike: Double, premium: Double, qty: Double = 3,
                             underlying: Double? = 707.73, right: OptionRight = .call,
                             close: Double? = nil, closed: Bool = true) -> Trade {
        let leg = Leg(kind: .option(right: right, strike: strike, expiry: Date()))
        var fills = [Fill(legID: leg.id, time: Date(), side: .buy,
                          quantity: qty, price: premium, underlying: underlying)]
        if closed {
            fills.append(Fill(legID: leg.id, time: Date().addingTimeInterval(600),
                              side: .sell, quantity: qty, price: premium * 1.8,
                              underlying: underlying))
        }
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills,
                     finalUnderlying: close)
    }

    // ── 真实那一笔 ─────────────────────────────────────────────────────

    func testTheRealBugFromUsersFirstBackup() {
        let f = Sanity.check(optionTrade(strike: 402, premium: 1.34, close: 709))
        let hit = f.first { $0.code == "strike_below_intrinsic" }
        XCTAssertNotNil(hit, "★ 用户真备份里的那笔必须被拦下")
        XCTAssertEqual(hit?.level, .blocked)
        XCTAssertTrue(hit!.detail.contains("总金额被当成行权价"),
                      "要说清是哪种填错,不能只说「校验失败」:\(hit!.detail)")
        XCTAssertTrue(hit!.detail.contains("402"))
    }

    func testCorrectStrikePasses() {
        // 同一笔,行权价换成真实的 708 —— 虚值 call,权利金 1.34 完全合理
        XCTAssertTrue(Sanity.check(optionTrade(strike: 708, premium: 1.34, close: 709))
                        .filter { $0.level == .blocked }.isEmpty)
    }

    func testPutBelowIntrinsicIsAlsoCaught() {
        // put 的内在价值是 strike − underlying,方向反过来也要成立
        let f = Sanity.blocking(optionTrade(strike: 900, premium: 2.0,
                                            right: .put, close: 709))
        XCTAssertEqual(f.first?.code, "strike_below_intrinsic")
    }

    func testDeepITMWithHonestPremiumIsNotFlagged() {
        // 行权价 402、标的 707.73,但权利金老老实实是 306 —— 这就是**合法的**深度实值
        XCTAssertTrue(Sanity.blocking(optionTrade(strike: 402, premium: 306, close: 709)).isEmpty,
                      "深度实值本身不是错,错的是「价格低于内在价值」")
    }

    func testNoUnderlyingMeansNoJudgement() {
        // 没记标的价就没法判 —— 不许瞎猜,直接跳过
        XCTAssertTrue(Sanity.blocking(optionTrade(strike: 402, premium: 1.34,
                                                  underlying: nil, close: 709)).isEmpty)
    }

    // ── 第二个发现:那笔存下来一条分析都出不来 ────────────────────────

    func testClosedTradeWithNoCounterfactualInputIsFlagged() {
        let f = Sanity.check(optionTrade(strike: 708, premium: 1.34, close: nil))
        XCTAssertEqual(f.first { $0.code == "no_counterfactual_input" }?.level, .warn,
                       "★ 已平仓却没有收盘价/峰值价 = 四条替代路线一条也算不出")
    }

    func testFillingCloseRemovesTheWarning() {
        XCTAssertNil(Sanity.check(optionTrade(strike: 708, premium: 1.34, close: 709.5))
                        .first { $0.code == "no_counterfactual_input" })
    }

    func testOpenTradeIsNotNaggedAboutClosePrice() {
        // 还没平仓,当然没有收盘反事实可算 —— 不该在这时候烦用户
        XCTAssertNil(Sanity.check(optionTrade(strike: 708, premium: 1.34, closed: false))
                        .first { $0.code == "no_counterfactual_input" })
    }

    func testWildStrikeGetsAWarning() {
        let f = Sanity.check(optionTrade(strike: 70, premium: 1.34, right: .put, close: 709))
        XCTAssertTrue(f.contains { $0.code == "strike_far_from_underlying" || $0.level == .blocked })
    }
}
