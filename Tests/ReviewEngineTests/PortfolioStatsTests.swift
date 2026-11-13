import XCTest
@testable import ReviewEngine

/// 跨笔汇总。主角是**反事实的累计**,不是盈亏 —— 盈亏券商 App 已经告诉你了。
final class PortfolioStatsTests: XCTestCase {

    private func trade(day: Int, buy: Double, sell: Double, qty: Double = 3,
                       strike: Double = 708, final: Double? = 709.5,
                       peak: Double? = 712) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let e = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: strike, expiry: e))
        var t0 = c; t0.hour = 10; t0.minute = 13
        var t1 = c; t1.hour = 10; t1.minute = 35
        let cal = Calendar(identifier: .gregorian)
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: cal.date(from: t0)!, side: .buy,
                 quantity: qty, price: buy, underlying: 709.94),
            Fill(legID: leg.id, time: cal.date(from: t1)!, side: .sell,
                 quantity: qty, price: sell, underlying: 710.20),
        ], peakUnderlying: peak, finalUnderlying: final)
    }

    func testAggregatesCounterfactualsAcrossTrades() {
        let s = PortfolioStats.compute([
            trade(day: 1, buy: 1.34, sell: 2.41),
            trade(day: 2, buy: 2.00, sell: 1.20),
            trade(day: 3, buy: 0.80, sell: 1.60),
        ])
        XCTAssertEqual(s.nClosed, 3)
        XCTAssertEqual(s.nWithCounterfactuals, 3)
        XCTAssertFalse(s.counterfactuals.isEmpty, "★ 这一页的主角")
        let hold = s.counterfactuals.first { $0.id == "hold_to_close" }
        XCTAssertNotNil(hold)
        XCTAssertEqual(hold!.n, 3, "三笔都算得出「持有到收盘」")
        XCTAssertEqual(hold!.alternativeBetter + hold!.youWereBetter, 3)
        // 排序:可执行的在前(与复盘页一致)
        XCTAssertEqual(s.counterfactuals.first?.id, "hold_to_close")
        XCTAssertEqual(s.counterfactuals.last?.id, "exit_vs_peak")
    }

    /// ★ 规范 [C2]:n<10 必须明说「不能用来下结论」。
    func testSampleSizeDisciplineIsEnforced() {
        XCTAssertEqual(PortfolioStats.compute([trade(day: 1, buy: 1, sell: 2)]).confidence, .tooFew)
        let ten = (1...10).map { trade(day: min($0, 28), buy: 1, sell: 2) }
        XCTAssertEqual(PortfolioStats.compute(ten).confidence, .indicative)
        let thirty = (1...30).map { trade(day: ($0 % 28) + 1, buy: 1, sell: 2) }
        XCTAssertEqual(PortfolioStats.compute(thirty).confidence, .usable)
        XCTAssertTrue(PortfolioStats.compute([trade(day: 1, buy: 1, sell: 2)])
            .confidence.banner.contains("不能用来下结论"))
    }

    /// ★★ never_happened:规范说它通常比已发生的统计更重要。
    func testNeverHappenedSurfacesUntestedRisk() {
        let allWins = (1...3).map { trade(day: $0, buy: 1.0, sell: 2.0) }
        let s = PortfolioStats.compute(allWins)
        // ★ 这些测试数据没有止损、也没有分钟路径 ⇒ 正确答案是「**还不知道**」,
        //   而不是「从未被检验」。后者是**推断**,前者是事实。
        //   (2026-09-02:有了真实路径之后发现用户 4 笔里 3 笔其实碰到过止损位 ——
        //    原来那句断言把「没亏钱」当成了「止损没被碰过」。)
        XCTAssertTrue(s.neverHappened.contains { $0.contains("全是盈利单") },
                      "全胜必须被点出来。实际:\(s.neverHappened)")
        XCTAssertTrue(s.neverHappened.contains { $0.contains("还不知道") },
                      "没止损也没路径 ⇒ 只能说不知道,不许推断。实际:\(s.neverHappened)")
        XCTAssertTrue(s.neverHappened.contains { $0.contains("逆势加仓") })
        XCTAssertTrue(s.neverHappened.contains { $0.contains("多腿") })
    }

    /// 没填收盘价的笔数要被明确报出来,而不是默默少算。
    func testUncoveredTradesAreReported() {
        let s = PortfolioStats.compute([
            trade(day: 1, buy: 1, sell: 2),
            trade(day: 2, buy: 1, sell: 2, final: nil, peak: nil),
        ])
        XCTAssertEqual(s.nClosed, 2)
        XCTAssertEqual(s.nWithCounterfactuals, 1)
        XCTAssertTrue(s.neverHappened.contains { $0.contains("还没填收盘价") })
    }

    /// 未平仓的不进统计(它们的盈亏还不存在)。
    func testOpenTradesExcluded() {
        let leg = Leg(kind: .equity)
        let open = Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                         fills: [Fill(legID: leg.id, time: Date(), side: .buy,
                                      quantity: 100, price: 709)])
        let s = PortfolioStats.compute([open, trade(day: 1, buy: 1, sell: 2)])
        XCTAssertEqual(s.nTotal, 2)
        XCTAssertEqual(s.nClosed, 1)
    }

    /// 逆势加仓要被计出来(它是用户自述死亡模式的关键一步)。
    func testUnderwaterAddIsCounted() {
        var t = trade(day: 1, buy: 2.00, sell: 1.50)
        let leg = t.legs[0]
        t.fills.insert(Fill(legID: leg.id, time: t.fills[0].time.addingTimeInterval(600),
                            side: .buy, quantity: 3, price: 1.40, underlying: 708),
                       at: 1)
        t.fills[2].quantity = 6      // 全平
        let s = PortfolioStats.compute([t])
        let p = s.patterns.first { $0.id == "added_while_underwater" }
        XCTAssertEqual(p?.hit, 1)
        XCTAssertFalse(s.neverHappened.contains { $0.contains("逆势加仓") },
                       "发生过就不该出现在 never_happened 里")
    }
}

/// 头条数字不许取「峰值出场」—— 那是事后视角,整个 App 都在警告不要信它。
final class HeroVerdictTests: XCTestCase {

    func testHeroExcludesNonExecutablePeakAlternative() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 1
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let e = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 717, expiry: e))
        var t0 = c; t0.hour = 10; t0.minute = 30
        var t1 = c; t1.hour = 11; t1.minute = 2
        let cal = Calendar(identifier: .gregorian)
        let tr = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: cal.date(from: t0)!, side: .buy,  quantity: 3, price: 1.97, underlying: 717.24),
            Fill(legID: leg.id, time: cal.date(from: t1)!, side: .sell, quantity: 3, price: 2.51, underlying: 718.04),
        ], peakUnderlying: 719.05, finalUnderlying: 715.56)

        let s = PortfolioStats.compute([tr])
        XCTAssertTrue(s.counterfactuals.contains { $0.id == "exit_vs_peak" }, "图上仍然画它")
        XCTAssertFalse(s.executableAlternatives.contains { $0.id == "exit_vs_peak" },
                       "★ 但头条不许用它")
        XCTAssertFalse(s.bestAlternativeLabel?.contains("峰值") ?? false)
        // 这笔里三条可执行方案都更差 ⇒ 头条应判「你赢了」(≤0)
        XCTAssertLessThanOrEqual(s.vsBestAlternative ?? 1, 0,
                                 "三条可执行方案都不如他,头条不该显示成他输了")
    }
}
