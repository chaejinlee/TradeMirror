import XCTest
@testable import ReviewEngine

/// 真实分钟路径能算出来的东西。
/// ★ 数据是**用户 2026-09-01 那笔的真实路径**(moomoo 实测,10:13→10:36 的 QQQ 708C)。
final class PathTests: XCTestCase {

    /// 真实分钟 K(high, low),按顺序。入场 1.34,出场 2.41。
    static let realBars: [(Double, Double)] = [
        (1.42, 1.24), (1.35, 1.19), (1.50, 1.27), (1.90, 1.36), (1.92, 1.66),
        (1.83, 1.57), (1.66, 1.39), (1.50, 1.37), (1.66, 1.49), (1.70, 1.57),
        (1.92, 1.56), (1.85, 1.59), (1.69, 1.54), (1.85, 1.63), (1.89, 1.78),
        (1.86, 1.57), (1.69, 1.60), (1.69, 1.55), (2.02, 1.65), (2.35, 1.92),
        (2.28, 2.14), (2.42, 2.24), (2.44, 2.37),
    ]

    private func path() -> [PriceBar] {
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        return Self.realBars.enumerated().map { i, hl in
            PriceBar(t: t0.addingTimeInterval(Double(i) * 60), h: hl.0, l: hl.1, c: hl.1)
        }
    }

    // ── 真 MAE / 真 MFE ──────────────────────────────────────────────

    func testTrueMAEIsNoLongerAGreaterThanEstimate() {
        // 旧版只看成交点,只能说「≥」。真值:最低 1.19,相对 1.34 是 −11.2%
        let mae = PathAnalysis.trueMAE(path: path(), entry: 1.34, isLong: true)
        XCTAssertEqual(mae ?? .nan, -11.194, accuracy: 0.01)
    }

    func testTrueMFE() {
        // 最高 2.44 -> +82.1%
        XCTAssertEqual(PathAnalysis.trueMFE(path: path(), entry: 1.34, isLong: true) ?? .nan,
                       82.09, accuracy: 0.01)
    }

    func testMFECaptureRate() {
        // 出场 2.41:(2.41−1.34)/1.34 = 79.9%,占 MFE 82.1% 的 97%
        let cap = PathAnalysis.mfeCapture(path: path(), entry: 1.34, exit: 2.41, isLong: true)
        XCTAssertEqual(cap ?? .nan, 0.973, accuracy: 0.005)
    }

    func testShortLegFlipsBothDirections() {
        // 做空腿:不利 = 涨,有利 = 跌。方向反了就全错。
        XCTAssertEqual(PathAnalysis.trueMAE(path: path(), entry: 1.34, isLong: false) ?? .nan,
                       -82.09, accuracy: 0.01)
        XCTAssertEqual(PathAnalysis.trueMFE(path: path(), entry: 1.34, isLong: false) ?? .nan,
                       11.194, accuracy: 0.01)
    }

    // ── 移动止损 ────────────────────────────────────────────────────

    func testTwentyFivePercentTrailWouldActuallyHaveBeenHit() {
        // ★★ 我原来断言「这笔一路走高,25% 从未触发」—— **错的,而且是我没查数据就写的**。
        //   真实路径:10:17 高 1.92 -> 10:19 低 1.39,中途回撤 **27.6%**。
        //   25% 的移动止损**会**在 1.44 被打掉。
        //   这正是这条反事实存在的意义:那笔看着是干净的 +80%,
        //   实际中途有一段足以打掉止损的回撤。
        XCTAssertEqual(PathAnalysis.trailingStopExit(path: path(), entry: 1.34,
                                                     trailPct: 25, isLong: true) ?? .nan,
                       1.44, accuracy: 0.001)
    }

    func testLooseEnoughTrailSurvives() {
        // 35% 就宽到扛得住那段 27.6% 的回撤
        XCTAssertNil(PathAnalysis.trailingStopExit(path: path(), entry: 1.34,
                                                   trailPct: 35, isLong: true))
    }

    func testNoLookaheadWithinABar() {
        // ★ 同一根 K 里 low 在前、high 在后时,不许用后来的 high 抬高止损去打掉前面的 low。
        //   1.36 -> 1.90 那一分钟:若先更新最高,止损会被抬到 1.425 并「打掉」1.36。
        let bar = [PriceBar(t: Date(), h: 1.90, l: 1.36, c: 1.90)]
        XCTAssertNil(PathAnalysis.trailingStopExit(path: bar, entry: 1.80,
                                                   trailPct: 25, isLong: true),
                     "止损位只能由**已完成**的信息决定")
    }

    func testTightTrailingStopGetsHitEarly() {
        // 10% 就会被早期那段回撤打掉:1.42 高点 -> 止损 1.278,第二根 low 1.19 击穿
        let px = PathAnalysis.trailingStopExit(path: path(), entry: 1.34,
                                               trailPct: 10, isLong: true)
        XCTAssertEqual(px ?? .nan, 1.278, accuracy: 0.001)
    }

    func testTrailingStopNeverGoesBelowEntryTrail() {
        // 峰值从入场价起算 —— 一开始就跌的话,止损是 entry×(1−pct)
        let down = [PriceBar(t: Date(), h: 1.30, l: 1.00, c: 1.00)]
        XCTAssertEqual(PathAnalysis.trailingStopExit(path: down, entry: 1.34,
                                                     trailPct: 10, isLong: true) ?? .nan,
                       1.206, accuracy: 0.001)
    }

    func testEmptyPathYieldsNothingRatherThanZero() {
        // 没有路径就返回 nil,**不返回 0 冒充结果**
        XCTAssertNil(PathAnalysis.trueMAE(path: [], entry: 1.34, isLong: true))
        XCTAssertNil(PathAnalysis.trailingStopExit(path: [], entry: 1.34,
                                                   trailPct: 25, isLong: true))
    }

    // ── 接进反事实 ──────────────────────────────────────────────────

    private func realTrade(withPath: Bool) -> Trade {
        let expiry = ISO8601DateFormatter().date(from: "2026-09-01T20:00:00Z")!
        var leg = Leg(kind: .option(right: .call, strike: 708, expiry: expiry))
        if withPath { leg.path = path() }
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 3, price: 1.34),
            Fill(legID: leg.id, time: t0.addingTimeInterval(1320), side: .sell,
                 quantity: 3, price: 2.41),
        ], finalUnderlying: 707.64)
    }

    func testTrailingStopCounterfactualAppearsOnlyWithPath() {
        XCTAssertNil(CounterfactualEngine.trailingStop(trade: realTrade(withPath: false),
                                                       trailPct: 25),
                     "★ 没有路径就不出现,不编一个数")
        XCTAssertNotNil(CounterfactualEngine.trailingStop(trade: realTrade(withPath: true),
                                                          trailPct: 25))
    }

    func testTwentyFivePercentTrailWouldHaveCostMost0fTheProfit() {
        // 被打在 1.44:(1.44−1.34)×3×100 = +$30,而实际拿到 +$321
        let cf = CounterfactualEngine.trailingStop(trade: realTrade(withPath: true), trailPct: 25)!
        XCTAssertEqual(cf.alternativePnL, 30, accuracy: 0.01)
        XCTAssertEqual(cf.verdict, .youWereBetter, "★ 这笔上,25% 移动止损会砍掉 91% 的利润")
    }

    func testNotStoppedMeansSameAsActual() {
        // 用一条单调上行的路径:全程没触发 -> 与实际同价,不该凭空多出或少掉钱
        var leg = Leg(kind: .equity)
        let t0 = Date()
        leg.path = (0..<10).map { i in
            PriceBar(t: t0.addingTimeInterval(Double(i) * 60),
                     h: 10 + Double(i), l: 9.5 + Double(i), c: 10 + Double(i))
        }
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 100, price: 10),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .sell,
                 quantity: 100, price: 19),
        ])
        let cf = CounterfactualEngine.trailingStop(trade: t, trailPct: 25)!
        XCTAssertEqual(cf.alternativePnL, cf.actualPnL, accuracy: 1e-9)
        XCTAssertTrue(cf.note?.contains("没被打掉") ?? false)
    }

    func testTightStopWouldHaveBeenWorse() {
        // 10%:第一根之前止损在 1.34×0.9 = 1.206,第一根 low 1.24 没破;
        // 更新最高到 1.42 后止损 1.278,第二根 low 1.19 击穿 -> 1.278
        let cf = CounterfactualEngine.trailingStop(trade: realTrade(withPath: true), trailPct: 10)!
        XCTAssertEqual(cf.alternativePnL, (1.278 - 1.34) * 3 * 100, accuracy: 0.5)
        XCTAssertEqual(cf.verdict, .youWereBetter, "★ 这笔上,紧的移动止损会更差")
    }
}

/// 「平一半 + 剩余移动止损」的**完整版** —— 曾经是「算不了的」清单上的第一条。
final class ScaleOutTrailTests: XCTestCase {

    /// 出场后价格继续走:2.41 → 高 3.00 → 回落 → 收在 0.25(末日权归零那一路)
    private func tradeWithAfterPath() -> Trade {
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        let exit = t0.addingTimeInterval(1320)              // 10:35
        var leg = Leg(kind: .option(right: .call, strike: 708,
                                    expiry: t0.addingTimeInterval(21000)))
        leg.userClosePrice = 0.25
        // 持仓段(简化)+ 出场后段
        var bars = [PriceBar(t: t0, h: 1.42, l: 1.24, c: 1.30),
                    PriceBar(t: exit, h: 2.44, l: 2.37, c: 2.41)]
        for (i, hl) in [(3.00, 2.50), (2.80, 2.10), (2.20, 1.60), (1.70, 0.90)].enumerated() {
            bars.append(PriceBar(t: exit.addingTimeInterval(Double(i + 1) * 300),
                                 h: hl.0, l: hl.1, c: hl.1))
        }
        leg.path = bars
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 4, price: 1.34),
            Fill(legID: leg.id, time: exit, side: .sell, quantity: 4, price: 2.41),
        ], finalUnderlying: 707.64)
    }

    func testFullVersionNowComputes() {
        XCTAssertNotNil(CounterfactualEngine.scaleOutAndTrail(
            trade: tradeWithAfterPath(), trailPct: 25, finalUnderlying: 707.64),
            "★ 有了出场之后的路径,这条不再是「算不了的」")
    }

    func testHalfAtExitAndRestGetsTrailed() {
        let cf = CounterfactualEngine.scaleOutAndTrail(
            trade: tradeWithAfterPath(), trailPct: 25, finalUnderlying: 707.64)!
        // 平 2 @ 2.41;剩 2 从 2.41 起跟踪:高 3.00 -> 止损 2.25,下一根 low 2.10 击穿
        // 成本 −4×1.34×100 = −536;收 2×2.41×100 + 2×2.25×100 = 482 + 450 = 932
        XCTAssertEqual(cf.alternativePnL, 932 - 536, accuracy: 1.0)
        XCTAssertTrue(cf.note?.contains("移动止损打掉") ?? false, cf.note ?? "nil")
    }

    func testNoPathMeansNoCounterfactualRatherThanAGuess() {
        var t = tradeWithAfterPath()
        for i in t.legs.indices { t.legs[i].path = nil }
        XCTAssertNil(CounterfactualEngine.scaleOutAndTrail(trade: t, trailPct: 25,
                                                           finalUnderlying: 707.64),
                     "没路径就不出现,**不编**")
    }

    func testRestFallsBackToYourRealClosePriceWhenNeverStopped() {
        // 极宽的止损:永远不触发 -> 剩下那一半按你填的真实收盘价 0.25 了结
        let cf = CounterfactualEngine.scaleOutAndTrail(
            trade: tradeWithAfterPath(), trailPct: 95, finalUnderlying: 707.64)!
        // 收 2×2.41×100 + 2×0.25×100 = 482 + 50 = 532;成本 536 -> −4
        XCTAssertEqual(cf.alternativePnL, -4, accuracy: 1.0)
        XCTAssertTrue(cf.note?.contains("没被打掉") ?? false, cf.note ?? "nil")
    }
}

/// ★★ 同一条路径,不同的问题要切不同的窗。
/// 实测踩过:路径从「入场→出场」扩到「入场→收盘」后,
/// MAE 从 −11.2% 变成 −93.3% —— 那是全天极值,不是持仓期间的。
final class PathSliceTests: XCTestCase {

    private func fullDay() -> [PriceBar] {
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        return [
            PriceBar(t: t0,                              h: 1.42, l: 1.24, c: 1.30), // 持仓中
            PriceBar(t: t0.addingTimeInterval(600),      h: 1.90, l: 1.19, c: 1.80), // 持仓中(最低)
            PriceBar(t: t0.addingTimeInterval(1320),     h: 2.44, l: 2.37, c: 2.41), // 出场
            PriceBar(t: t0.addingTimeInterval(7200),     h: 4.40, l: 3.90, c: 4.00), // 走之后
            PriceBar(t: t0.addingTimeInterval(20000),    h: 0.30, l: 0.09, c: 0.25), // 收盘归零
        ]
    }

    func testSliceKeepsOnlyTheHoldingWindow() {
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        let held = PathAnalysis.slice(fullDay(), from: t0, to: t0.addingTimeInterval(1320))
        XCTAssertEqual(held.count, 3)
        XCTAssertEqual(PathAnalysis.trueMAE(path: held, entry: 1.34, isLong: true) ?? .nan,
                       -11.19, accuracy: 0.02, "持仓期间的最低是 1.19,不是当天的 0.09")
        XCTAssertEqual(PathAnalysis.trueMFE(path: held, entry: 1.34, isLong: true) ?? .nan,
                       82.09, accuracy: 0.02, "持仓期间的最高是 2.44,不是当天的 4.40")
    }

    func testUnslicedWouldGiveTheWrongAnswer() {
        // 这就是我踩的那个坑:不切窗 -> 拿全天极值冒充持仓极值
        XCTAssertEqual(PathAnalysis.trueMAE(path: fullDay(), entry: 1.34, isLong: true) ?? .nan,
                       -93.28, accuracy: 0.02)
        XCTAssertEqual(PathAnalysis.trueMFE(path: fullDay(), entry: 1.34, isLong: true) ?? .nan,
                       228.36, accuracy: 0.02)
    }

    func testSliceFromOnlyKeepsTheTail() {
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        XCTAssertEqual(PathAnalysis.slice(fullDay(), from: t0.addingTimeInterval(1320)).count, 3)
    }
}
