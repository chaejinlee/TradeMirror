import XCTest
@testable import ReviewEngine

/// **仓位截图**(不是成交明细截图)。
///
/// ★★ 用户 2026-09-03:「我放了仓位截图进去之后软件没识别出来是平仓订单,
///   因为和之前的格式不一样没显示盈亏金额,但是理论上软件应该能自己计算出来」。
///
///   查下来是两个毛病叠在一起:
///   ① 方向判定是「先找 buyWords,找到就定案」——
///      而仓位截图上「开仓均价」和「平仓均价」**同时存在**,`开仓` 命中在前,
///      于是一张平仓截图被判成买入,合并时变成**加仓**而不是平仓。
///   ② 把 `开仓均价` 这种**字段名**当成了动作。
///
///   还有第三件事,也是用户点破的:<b>盈亏本来就不需要截图告诉我们。</b>
///   开仓价和平仓价都在图上,一来一回摆出来,盈亏是算出来的。
final class PositionScreenshotTests: XCTestCase {

    // ── ① 方向:字段名不是动作 ──────────────────────────────────────

    /// ★ 回归:同一张图里「开仓均价」和「平仓」都有,必须判成**卖出**。
    ///   (旧实现判成买入 —— 把这条改回 first-match 它就会红。)
    func testPositionScreenshotWithBothWordsIsRecognisedAsClosing() {
        let side = ScreenshotParser.judgeSide([
            "QQQ 250903C718000",
            "开仓均价 2.15",
            "平仓 15:32",
        ])
        XCTAssertEqual(side?.value, .sell, "「开仓均价」是字段名,「平仓」才是动作")
    }

    /// 只有字段名、没有任何动作词 ⇒ **不猜**,让界面问用户。
    func testOnlyFieldLabelsGivesNoSide() {
        let side = ScreenshotParser.judgeSide([
            "QQQ 250903C718000",
            "开仓均价 2.15",
            "平仓均价 3.40",
            "持仓数量 1",
        ])
        XCTAssertNil(side, "两边都只是字段名 ⇒ 分不出来就说分不出来")
    }

    /// 普通的成交明细截图不能被这次改动弄坏。
    func testPlainFillScreenshotsStillWork() {
        XCTAssertEqual(ScreenshotParser.judgeSide(["买入 QQQ", "成交均价 2.17"])?.value, .buy)
        XCTAssertEqual(ScreenshotParser.judgeSide(["卖出 QQQ", "成交均价 2.51"])?.value, .sell)
        XCTAssertEqual(ScreenshotParser.judgeSide(["BOT 2 QQQ 06AUG26 708 C @2.17"])?.value, .buy)
        XCTAssertEqual(ScreenshotParser.judgeSide(["SLD 3 QQQ 06AUG26 708 C @2.51"])?.value, .sell)
    }

    /// 「close price」是列名,不是动作 —— 别把它当成卖出。
    func testEnglishColumnHeadersAreNotActions() {
        XCTAssertNil(ScreenshotParser.judgeSide(["QQQ", "Close price 3.40", "Open price 2.15"]))
    }

    // ── ② 两个价 ⇒ 一来一回,盈亏自己算 ──────────────────────────────

    /// ★★ 用户那句话的正解:开仓价 + 平仓价都在图上,
    ///   <b>盈亏不用截图印出来,自己就能算</b>。
    func testEntryAndExitPricesBecomeAClosedTrade() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 250903C 718",
            "持仓数量 2",
            "开仓均价 2.15",
            "平仓均价 3.40",
        ])
        XCTAssertEqual(p.price?.value ?? 0, 2.15, accuracy: 1e-9, "price = 开仓均价")
        XCTAssertEqual(p.exitPrice?.value ?? 0, 3.40, accuracy: 1e-9, "exitPrice = 平仓均价")
        XCTAssertEqual(p.quantity?.value ?? 0, 2, accuracy: 1e-9)

        // 用这份草稿拼出交易 —— 盈亏应当是算出来的
        let leg = Leg(kind: .option(right: .call, strike: 718, expiry: Date()))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy,  quantity: 2, price: 2.15),
            Fill(legID: leg.id, time: Date(), side: .sell, quantity: 2, price: 3.40),
        ])
        XCTAssertTrue(t.isClosed)
        XCTAssertEqual(t.displayablePnL ?? 0, 250, accuracy: 1e-6)   // (3.40−2.15)×2×100
    }

    /// ★ 方向没写明时按**多头**,但信心压低 —— 做空时盈亏是反的,不能悄悄默认。
    func testDirectionDefaultsToLongButWithLowConfidence() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ", "持仓数量 1", "开仓均价 2.15", "平仓均价 3.40",
        ])
        XCTAssertEqual(p.side?.value, .buy)
        XCTAssertLessThan(p.side?.confidence ?? 1, 0.6,
                          "默认值必须低于 0.6 —— 界面靠这个把它高亮出来让用户核对")
    }

    /// 明确写了做空 ⇒ 开仓那一边是**卖出**。
    func testExplicitShortMarkerFlipsTheOpeningSide() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 空头", "持仓数量 1", "开仓均价 3.40", "平仓均价 2.15",
        ])
        XCTAssertEqual(p.side?.value, .sell)
        XCTAssertGreaterThan(p.side?.confidence ?? 0, 0.6)
    }

    /// ★ 只有一个价时**不许**臆造出一笔平仓 —— 那就是普通的成交均价。
    func testSinglePriceDoesNotInventAnExit() {
        let p = ScreenshotParser.parse(lines: [
            "买入 QQQ", "成交数量 2", "成交均价 2.17",
        ])
        XCTAssertNil(p.exitPrice, "一个价就是一笔成交,不该凭空多出一笔平仓")
        XCTAssertEqual(p.price?.value ?? 0, 2.17, accuracy: 1e-9)
    }

    /// 英文版式的同一件事。
    func testEnglishPositionScreenshot() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 250903C718000",
            "Quantity 3",
            "Avg cost 1.20",
            "Avg close 0.85",
        ])
        XCTAssertEqual(p.price?.value ?? 0, 1.20, accuracy: 1e-9)
        XCTAssertEqual(p.exitPrice?.value ?? 0, 0.85, accuracy: 1e-9)
        XCTAssertEqual(p.quantity?.value ?? 0, 3, accuracy: 1e-9)
    }
}

/// 仓位截图**并进已有持仓**时的行为。
///
/// ★★ 这是我改上面那两条时差点造出来的新 bug:仓位截图给的是**整段**
///   (开仓价 + 平仓价),而要并进去的那笔<b>开仓已经记过了</b> ——
///   再按 `parsed.price`(开仓价)追加一笔就成了「又加了一次仓」,
///   和用户报的「没识别成平仓」是同一个病,只是换了个入口。
final class PositionScreenshotMergeTests: XCTestCase {

    private func openTrade() -> (Trade, Leg) {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 3
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 718,
                                    expiry: t0.addingTimeInterval(21600)))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 2, price: 2.15),
        ])
        return (t, leg)
    }

    func testMergingAPositionScreenshotClosesInsteadOfAddingOn() {
        let (t, leg) = openTrade()
        XCTAssertFalse(t.isClosed)
        let parsed = ScreenshotParser.parse(lines: [
            "QQQ 250903C 718", "持仓数量 2", "开仓均价 2.15", "平仓均价 3.40",
        ])
        let merged = TradeMatcher.appendFill(parsed, to: t, leg: leg, at: Date())
        XCTAssertNotNil(merged)
        XCTAssertTrue(merged!.isClosed, "并完应该是**平掉**,不是加仓")
        XCTAssertEqual(merged!.displayablePnL ?? 0, 250, accuracy: 1e-6)
        XCTAssertEqual(merged!.fills.count, 2)
    }

    /// 手上只有 1 张、截图写 2 张 ⇒ 只平 1 张,不许平出负数持仓。
    func testCannotCloseMoreThanIsHeld() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 3
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 718,
                                    expiry: t0.addingTimeInterval(21600)))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: 2.15),
        ])
        let parsed = ScreenshotParser.parse(lines: [
            "QQQ", "持仓数量 2", "开仓均价 2.15", "平仓均价 3.40",
        ])
        let merged = TradeMatcher.appendFill(parsed, to: t, leg: leg, at: Date())!
        XCTAssertEqual(merged.netQuantity(of: leg), 0, "刚好平完,不许变成 −1")
        XCTAssertEqual(merged.displayablePnL ?? 0, 125, accuracy: 1e-6)
    }

    /// 普通的一笔平仓截图(只有一个成交价)照旧走原来的路。
    func testPlainClosingFillStillAppendsNormally() {
        let (t, leg) = openTrade()
        let parsed = ScreenshotParser.parse(lines: [
            "卖出 QQQ", "成交数量 2", "成交均价 3.40",
        ])
        let merged = TradeMatcher.appendFill(parsed, to: t, leg: leg, at: Date())!
        XCTAssertTrue(merged.isClosed)
        XCTAssertEqual(merged.displayablePnL ?? 0, 250, accuracy: 1e-6)
    }
}
