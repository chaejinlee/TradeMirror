import XCTest
@testable import ReviewEngine

/// ★★ 一致性:**同一笔交易、同一个问题,不同的卡片必须给同一个数。**
///
/// 起因是 2026-09-01 用户在真机截图里逮到的 bug:同一屏上
/// 「若持有到收盘」用了他填的真实价 0.25(那样 −$327),
/// 「若平一半、剩余持有到强平」却还在用模型的 0(那样 $80)。
/// 根因是那段「这条腿收盘值多少」的逻辑被抄了三份,我只改了第一份。
final class ClosePriceConsistencyTests: XCTestCase {

    /// 用户那笔真实交易:QQQ 708C,买 3 @ 1.34,卖 3 @ 2.41,收盘真实价 0.25。
    private func realTrade(userClose: Double?) -> Trade {
        let expiry = ISO8601DateFormatter().date(from: "2026-09-01T20:00:00Z")!
        var leg = Leg(kind: .option(right: .call, strike: 708, expiry: expiry))
        leg.userClosePrice = userClose
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 3, price: 1.34),
            Fill(legID: leg.id, time: t0.addingTimeInterval(1320), side: .sell,
                 quantity: 3, price: 2.41),
        ], finalUnderlying: 707.64)
    }

    func testScaleOutHonoursYourRealClosePrice() {
        // 平 2 @ 2.41 = 482;留 1 @ 0.25 = 25;成本 402 ⇒ 105
        let t = realTrade(userClose: 0.25)
        let cf = CounterfactualEngine.scaleOutAndHold(trade: t, finalUnderlying: 707.64)!
        XCTAssertEqual(cf.alternativePnL, 105, accuracy: 0.01,
                       "★ 用户填的 0.25 必须被用上;用模型的 0 会算成 80")
    }

    func testWithoutYourPriceItFallsBackToIntrinsic() {
        let cf = CounterfactualEngine.scaleOutAndHold(trade: realTrade(userClose: nil),
                                                      finalUnderlying: 707.64)!
        XCTAssertEqual(cf.alternativePnL, 80, accuracy: 0.01)
    }

    func testEveryCardAgreesOnWhatTheLegIsWorthAtClose() {
        // ★ 这条是**总闸**:任何一张卡片自己另算一遍收盘价,这里就会红。
        let t = realTrade(userClose: 0.25)
        let leg = t.legs[0]
        let canonical = CounterfactualEngine.closePrice(of: leg, finalUnderlying: 707.64)
        XCTAssertEqual(canonical, 0.25)

        // ① 持有到收盘:全部 3 张按 canonical
        let hold = CounterfactualEngine.holdToClose(trade: t, finalUnderlying: 707.64)
        XCTAssertEqual(hold.alternativePnL, -402 + 3 * canonical * 100, accuracy: 0.01)

        // ② 平一半:2 张按实际出场价 + 1 张按 canonical
        let half = CounterfactualEngine.scaleOutAndHold(trade: t, finalUnderlying: 707.64)!
        XCTAssertEqual(half.alternativePnL,
                       -402 + 2 * 2.41 * 100 + 1 * canonical * 100, accuracy: 0.01)
    }

    func testStocksAndFuturesUseTheUnderlyingItself() {
        for kind in [LegKind.equity,
                     .futures(contract: "MNQ", pointValue: 2, tickSize: 0.25),
                     .forex(contractSize: 100_000)] {
            XCTAssertEqual(CounterfactualEngine.closePrice(of: Leg(kind: kind),
                                                           finalUnderlying: 123.45), 123.45)
        }
    }

    func testUserPriceWinsForEveryInstrument() {
        // 用户填的永远优先 —— 不分品种
        for kind in [LegKind.equity, .option(right: .put, strike: 700, expiry: Date()),
                     .futures(contract: "ES", pointValue: 50, tickSize: 0.25)] {
            var leg = Leg(kind: kind)
            leg.userClosePrice = 9.99
            XCTAssertEqual(CounterfactualEngine.closePrice(of: leg, finalUnderlying: 500), 9.99)
        }
    }

    func testTheStaleNoteIsGone() {
        // 「v1 拿不到」现在是假话:股票/期货/外汇点一下就有分钟 K
        let cf = CounterfactualEngine.scaleOutAndHold(trade: realTrade(userClose: 0.25),
                                                      finalUnderlying: 707.64)!
        XCTAssertFalse(cf.note?.contains("v1 拿不到") ?? false,
                       "措辞要按品种说准,不能一句「拿不到」盖住全部")
        XCTAssertTrue(cf.note?.contains("期权的分钟价") ?? false)
    }
}

/// 排序:**可执行的在前,事后视角的最后**(规范 §3.1)。
final class CounterfactualOrderTests: XCTestCase {

    func testPeakIsAlwaysLastEvenWithNewCards() {
        // ★ 新加的 trailing_stop / scale_out_trail 曾经因为没登记而排到「峰值出场」后面,
        //   把唯一一张**不可执行**的卡顶到了中间。
        let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!
        var leg = Leg(kind: .option(right: .call, strike: 708,
                                    expiry: t0.addingTimeInterval(21000)))
        leg.userClosePrice = 0.25
        leg.path = (0..<20).map {
            PriceBar(t: t0.addingTimeInterval(Double($0) * 60),
                     h: 1.4 + Double($0) * 0.06, l: 1.2 + Double($0) * 0.05,
                     c: 1.3 + Double($0) * 0.055)
        }
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            // ★ 必须带 underlying —— 「峰值出场」要靠它反解 IV,没有就整张卡不出现,
            //   而那正是这个测试要盯的那张。
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 4, price: 1.34,
                 underlying: 707.73),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .buy,
                 quantity: 2, price: 1.20, underlying: 707.20),
            Fill(legID: leg.id, time: t0.addingTimeInterval(1140), side: .sell,
                 quantity: 6, price: 2.41, underlying: 709.80),
        ], peakUnderlying: 712.30, finalUnderlying: 707.64)

        let ids = CounterfactualEngine.allByTime(trade: t, peakUnderlying: 712.30,
                                                 peakTime: nil, finalUnderlying: 707.64)
            .results.map(\.id)
        XCTAssertTrue(ids.contains("exit_vs_peak"))
        XCTAssertEqual(ids.last, "exit_vs_peak", "★ 事后视角那张必须垫底:\(ids)")
        XCTAssertEqual(ids.first, "hold_to_close", "可执行且最重要的那张打头:\(ids)")
    }

    func testRealPathMeansNoLongerMissingIntradayPath() {
        // 有真实路径就不该再报「缺分钟级路径」
        let t0 = Date()
        var leg = Leg(kind: .equity)
        leg.path = [PriceBar(t: t0, h: 11, l: 9, c: 10)]
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 10, price: 10),
            Fill(legID: leg.id, time: t0.addingTimeInterval(60), side: .sell,
                 quantity: 10, price: 11),
        ], finalUnderlying: 11)
        let missing = CounterfactualEngine.allByTime(trade: t, peakUnderlying: nil,
                                                     peakTime: nil, finalUnderlying: 11).missing
        XCTAssertFalse(missing.contains(.intradayPath))
    }
}

/// ★★ 全线复查(2026-09-01):用户那笔真实交易的**每一个数**,都对着手算的答案钉死。
///
/// 交易:QQQ 2026-09-01 $708 Call,买 3 @ 1.34,卖 3 @ 2.41。
/// 事实:QQQ 收 707.64、当日高 712.30(11:49);该期权收盘 0.25、峰值那分钟 4.29(moomoo 实测)。
final class FullAuditTests: XCTestCase {

    private let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!

    /// 简化但**关键点真实**的路径:入场→出场→标的峰值→收盘。
    private func trade() -> Trade {
        let expiry = ISO8601DateFormatter().date(from: "2026-09-01T20:00:00Z")!
        var leg = Leg(kind: .option(right: .call, strike: 708, expiry: expiry))
        leg.userClosePrice = 0.25
        let peakT = ISO8601DateFormatter().date(from: "2026-09-01T15:49:00Z")!   // 11:49 ET
        leg.path = [
            PriceBar(t: t0,                          h: 1.42, l: 1.19, c: 1.34),
            PriceBar(t: t0.addingTimeInterval(1320), h: 2.44, l: 2.37, c: 2.41),
            PriceBar(t: peakT,                       h: 4.29, l: 4.10, c: 4.29), // 真实
            PriceBar(t: expiry,                      h: 0.30, l: 0.09, c: 0.25),
        ]
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 3, price: 1.34,
                 underlying: 707.73),
            Fill(legID: leg.id, time: t0.addingTimeInterval(1320), side: .sell,
                 quantity: 3, price: 2.41, underlying: 709.80),
        ], peakUnderlying: 712.30, finalUnderlying: 707.64)
        t.underlyingPath = [
            PriceBar(t: t0,                          h: 708.5, l: 707.0, c: 707.7),
            PriceBar(t: t0.addingTimeInterval(1320), h: 710.1, l: 709.4, c: 709.8),
            PriceBar(t: peakT,                       h: 712.30, l: 711.5, c: 712.1),
            PriceBar(t: expiry,                      h: 708.0, l: 707.2, c: 707.64),
        ]
        return t
    }

    func testActualPnL() {
        XCTAssertEqual(trade().realizedPnL, 321, accuracy: 0.01)   // (2.41−1.34)×3×100
    }

    func testCostBasis() {
        XCTAssertEqual(trade().netDebit, 402, accuracy: 0.01)      // 1.34×3×100
    }

    func testHoldToClose() {
        // 收盘卖 3 @ 0.25 = 75;成本 402 => −327
        let cf = CounterfactualEngine.holdToClose(trade: trade(), finalUnderlying: 707.64)
        XCTAssertEqual(cf.alternativePnL, -327, accuracy: 0.01)
        XCTAssertEqual(cf.delta, -327 - 321, accuracy: 0.01, "你比它多赚 648")
    }

    func testScaleOutAndHold() {
        // 平 2 @ 2.41 = 482;留 1 @ 0.25 = 25;−402 => +105
        let cf = CounterfactualEngine.scaleOutAndHold(trade: trade(), finalUnderlying: 707.64)!
        XCTAssertEqual(cf.alternativePnL, 105, accuracy: 0.01)
    }

    func testExitAtPeakUsesRealPriceNotTheModel() {
        // ★ 真实:QQQ 11:49 触及 712.30,该期权当时 4.29 => 3×4.29×100 − 402 = +885
        //   模型(BS,常数 IV)给的是 4.45 => +933,**高估 $48**
        let cf = CounterfactualEngine.exitVsPeakFromPath(trade: trade())!
        XCTAssertEqual(cf.alternativePnL, 885, accuracy: 0.01)
        XCTAssertTrue(cf.note?.contains("真实价") ?? false, cf.note ?? "nil")
    }

    func testPeakMomentIsReadFromTheUnderlyingPath() {
        let p = CounterfactualEngine.peakMoment(of: trade())!
        XCTAssertEqual(p.px, 712.30, accuracy: 0.01, "峰值该从标的路径里读,不用用户手填")
    }

    func testAllByTimePrefersRealPeakOverModel() {
        let r = CounterfactualEngine.allByTime(trade: trade(), peakUnderlying: 712.30,
                                               peakTime: nil, finalUnderlying: 707.64)
        let peak = r.results.first { $0.id == "exit_vs_peak" }
        XCTAssertEqual(peak?.alternativePnL ?? .nan, 885, accuracy: 0.01,
                       "★ 有真实价就不许再用模型估的 933")
        XCTAssertEqual(r.results.last?.id, "exit_vs_peak", "而且它仍然垫底")
    }

    func testNoPathFallsBackToTheModelRatherThanNothing() {
        var t = trade()
        for i in t.legs.indices { t.legs[i].path = nil }
        t.underlyingPath = nil
        XCTAssertNil(CounterfactualEngine.exitVsPeakFromPath(trade: t))
        let r = CounterfactualEngine.allByTime(trade: t, peakUnderlying: 712.30,
                                               peakTime: nil, finalUnderlying: 707.64)
        XCTAssertNotNil(r.results.first { $0.id == "exit_vs_peak" }, "没路径时模型仍要兜底")
    }
}

/// ★★ 「同一张表只能有一份」的守卫。
/// 一个晚上踩了三次:短标签(2 份)、收盘价(3 份)、排序表(2 份)。
/// 每次都是加了新反事实、只改了其中一份 —— 而且**不会有任何报错**。
final class SingleSourceOfTruthTests: XCTestCase {

    /// ★ 从枚举取,不手写 —— 手写的清单本身就是第 N 份会过期的副本。
    private var allIDs: [String] { CFID.allCases.map(\.rawValue) }

    func testEveryIDHasAShortLabel() {
        for id in allIDs {
            XCTAssertNotEqual(counterfactualShortLabel(id), id,
                              "★ \(id) 忘了登记短标签 —— 图上会直接画出原始 id")
        }
    }

    func testEveryIDHasAnExplicitRank() {
        for id in allIDs {
            XCTAssertNotEqual(counterfactualRank(id), 500,
                              "★ \(id) 忘了登记排序 —— 会掉进默认档,顺序变成不确定")
        }
    }

    func testRanksAreUnique() {
        // 两张卡同名次 = 顺序不确定,每次可能不一样
        let ranks = CFID.allCases.map(\.rank)
        XCTAssertEqual(Set(ranks).count, ranks.count, "名次不能撞:\(ranks)")
    }

    func testEveryIDActuallyProducedByTheEngineIsRegistered() {
        // ★ 反向守卫:引擎真的产出过的 id,必须都在枚举里
        for raw in ["hold_to_close", "scale_out_hold", "scale_out_trail",
                    "trailing_stop", "no_add_on", "exit_vs_peak"] {
            XCTAssertNotNil(CFID(rawValue: raw), "引擎产出了 \(raw),但枚举里没有")
        }
    }

    func testPeakOutranksEverythingElse() {
        for id in allIDs where id != "exit_vs_peak" {
            XCTAssertLessThan(counterfactualRank(id), counterfactualRank("exit_vs_peak"),
                              "事后视角那张必须永远垫底")
        }
    }

    func testUnknownIDNeverOutranksPeak() {
        // 以后加了新卡忘了登记,也不许把「峰值出场」顶上去
        XCTAssertLessThan(counterfactualRank("something_new_i_forgot"),
                          counterfactualRank("exit_vs_peak"))
    }

    func testHistoryPageUsesTheSameOrderAsReviewPage() {
        // ★ 这条直接盯住那次真事故:两个页面用了两张表
        let ids = allIDs.shuffled().sorted { counterfactualRank($0) < counterfactualRank($1) }
        XCTAssertEqual(ids.last, "exit_vs_peak")
        XCTAssertEqual(ids.first, "hold_to_close")
    }

    func testNewExecutableCardsCountTowardTheHeroNumber() {
        // 主角数字只排除 exit_vs_peak;新加的两张是**可执行**的,必须参与竞争
        XCTAssertFalse(PortfolioStats.nonExecutable.contains("trailing_stop"))
        XCTAssertFalse(PortfolioStats.nonExecutable.contains("scale_out_trail"))
        XCTAssertTrue(PortfolioStats.nonExecutable.contains("exit_vs_peak"))
    }
}
