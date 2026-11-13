import XCTest
@testable import ReviewEngine

/// 用**用户真实截图上的文字与版式**写的测试(2026-09-01 Wealthsimple 期权成交详情)。
///
/// 与之前那些的区别:文字内容、标签措辞、数值、行的相对位置**全部照抄真图**,
/// 包括**状态栏**(手机时间 10:56、纳斯达克指数 29172.20、电量 88)——
/// 那正是合成图里永远不会有、却一定会污染解析的东西。
///
/// ⚠️ 仍未覆盖:像素级的 OCR 字符错误(0/O、1/l)。那要拿原图跑才知道。
final class WealthsimpleRealTests: XCTestCase {

    /// 买入那张。真实数据:买 3 张 @ $1.34,总成本 $402.00,成交于 10:13 am。
    static let buyLines = [
        "10:56  纳斯...  29172.20  88",          // ★ 状态栏:手机时间/指数/电量
        "QQQ Sep 1 $708 Call",
        "$402.00 USD",
        "Account  Day Trading",
        "Status  Completed",
        "Submitted  September 1, 2026",
        "10:13 am",
        "Filled  September 1, 2026",
        "10:13 am",
        "Type  Market buy",
        "Buy to open",
        "Time in force  Day order",
        "Entered quantity  3",
        "Filled quantity  3 x $1.34 USD",
        "Total cost  $402.00 USD",
        "View contract details",
        "View QQQ options",
        "View trade confirmation",
        "Duplicate order",
    ]

    /// 卖出那张。卖 3 张 @ $2.41,总值 $723.00,+$321.00 return,成交于 10:35 am。
    static let sellLines = [
        "10:56  纳斯...  29166.10  88",
        "QQQ Sep 1 $708 Call",
        "$723.00 USD",
        "Account  Day Trading",
        "Status  Completed",
        "Submitted  September 1, 2026",
        "10:35 am",
        "Filled  September 1, 2026",
        "10:35 am",
        "Type  Market sell",
        "Sell to close",
        "Time in force  Day order",
        "Entered quantity  3",
        "Filled quantity  3 x $2.41 USD",
        "Total value  $723.00 USD",
        "+$321.00 return",
        "View contract details",
    ]

    func testRealBuyScreenshot() {
        let p = ScreenshotParser.parse(lines: Self.buyLines)
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.right?.value, .call)
        XCTAssertEqual(p.strike?.value, 708)
        XCTAssertEqual(p.side?.value, .buy, "Market buy / Buy to open")
        XCTAssertEqual(p.quantity?.value, 3)
        XCTAssertEqual(p.price?.value ?? .nan, 1.34, accuracy: 1e-9, "3 × 1.34 × 100 = 402 闭合")
        XCTAssertEqual(p.expiry?.value.month, 9)
        XCTAssertEqual(p.expiry?.value.day, 1)
        // ★ 时间必须是**成交时间 10:13**,不是状态栏的手机时间 10:56
        XCTAssertEqual(p.time?.value.hour, 10)
        XCTAssertEqual(p.time?.value.minute, 13, "★ 抓到 56 就说明状态栏没被过滤掉")
        XCTAssertEqual(p.time?.value.day, 1, "日期在上一行,要接得上")
        XCTAssertTrue(p.isUsable)
    }

    func testRealSellScreenshot() {
        let p = ScreenshotParser.parse(lines: Self.sellLines)
        XCTAssertEqual(p.side?.value, .sell, "Market sell / Sell to close")
        XCTAssertEqual(p.quantity?.value, 3)
        XCTAssertEqual(p.price?.value ?? .nan, 2.41, accuracy: 1e-9, "3 × 2.41 × 100 = 723 闭合")
        XCTAssertEqual(p.strike?.value, 708)
        XCTAssertEqual(p.time?.value.minute, 35)
    }

    /// ★ 状态栏里的纳斯达克指数(29172.20)绝不能进候选数字池 —— 否则可能凑出假恒等式。
    func testStatusBarNumbersAreExcluded() {
        // 先把状态栏那一行单独抽一遍,看它到底吐了什么(防止「通过」是假通过)
        let bar = NumericSolver.extractNumbers(from: ["10:56  纳斯...  29172.20  88"])
        print("★ 状态栏单行抽出:", bar)
        let ns = NumericSolver.extractNumbers(from: Self.buyLines)
        print("★ 全页抽出:", ns)
        XCTAssertFalse(ns.contains(29172.20), "★ 状态栏的指数不该进来")
        XCTAssertFalse(ns.contains(88), "电量不该进来")
        XCTAssertTrue(ns.contains(3) && ns.contains(1.34) && ns.contains(402))
    }

    /// 两张合起来就是一笔完整交易:买 3@1.34 → 卖 3@2.41,盈亏 +$321。
    /// 截图里 Wealthsimple 自己写的就是 +$321.00 return —— 我们算出来必须一致。
    func testTwoScreenshotsFormOneRoundTrip() {
        let b = ScreenshotParser.parse(lines: Self.buyLines)
        let s = ScreenshotParser.parse(lines: Self.sellLines)
        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: Date()))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy,
                 quantity: b.quantity!.value, price: b.price!.value, underlying: 709.94),
            Fill(legID: leg.id, time: Date().addingTimeInterval(1320), side: .sell,
                 quantity: s.quantity!.value, price: s.price!.value, underlying: 710.20),
        ])
        XCTAssertEqual(t.realizedPnL, 321, accuracy: 1e-6,
                       "★ 与 Wealthsimple 自己显示的 +$321.00 return 必须一致")
        XCTAssertTrue(t.isClosed)
    }
}

/// 「两张截图 = 一笔交易」。用户 2026-09-01 那笔真单直接暴露的需求。
final class TradeMatcherTests: XCTestCase {

    /// 先导入买入截图建一笔,再导入卖出截图 —— 必须**并进同一笔**,不是新建。
    func testSellScreenshotMergesIntoOpenBuyTrade() {
        let buy = ScreenshotParser.parse(lines: WealthsimpleRealTests.buyLines)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        var ec = DateComponents(); ec.year = 2026; ec.month = 9; ec.day = 1
        ec.hour = 16; ec.timeZone = TradingDay.exchangeTimeZone
        let expiry = cal.date(from: ec)!

        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: expiry))
        let t0 = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy,
                 quantity: buy.quantity!.value, price: buy.price!.value, underlying: 709.94)])
        XCTAssertFalse(t0.isClosed)

        let sell = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        let m = TradeMatcher.find(for: sell, in: [t0], calendar: cal)
        XCTAssertNotNil(m, "★ 同一合约且未平完 —— 必须认出来是同一笔")
        XCTAssertTrue(m!.reason.contains("708"))

        let merged = TradeMatcher.appendFill(sell, to: m!.trade, leg: m!.leg,
                                             underlying: 710.20, at: Date().addingTimeInterval(1320))!
        XCTAssertTrue(merged.isClosed, "买 3 卖 3 ⇒ 已平")
        XCTAssertEqual(merged.realizedPnL, 321, accuracy: 1e-6,
                       "★ 与 Wealthsimple 显示的 +$321.00 一致")
        XCTAssertEqual(merged.fills.count, 2)
    }

    /// 已经平完的交易不该被继续追加(否则会把新的一笔并进旧单)。
    func testClosedTradeIsNotMatched() {
        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: Date()))
        let closed = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy,  quantity: 3, price: 1.34, underlying: 709),
            Fill(legID: leg.id, time: Date(), side: .sell, quantity: 3, price: 2.41, underlying: 710)])
        XCTAssertTrue(closed.isClosed)
        let sell = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        XCTAssertNil(TradeMatcher.find(for: sell, in: [closed]),
                     "已平完的不许再并进去")
    }

    /// 行权价不同 = 不同合约,绝不能并。
    func testDifferentStrikeDoesNotMatch() {
        let leg = Leg(kind: .option(right: .call, strike: 715, expiry: Date()))
        let other = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy, quantity: 3, price: 1.34, underlying: 709)])
        let sell = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)   // 708
        XCTAssertNil(TradeMatcher.find(for: sell, in: [other]), "708 ≠ 715,不是同一合约")
    }

    /// 期权截图不许并进股票腿。
    func testOptionScreenshotDoesNotMergeIntoStockLeg() {
        let leg = Leg(kind: .equity)
        let stock = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy, quantity: 100, price: 709, underlying: 709)])
        let sell = ScreenshotParser.parse(lines: WealthsimpleRealTests.sellLines)
        XCTAssertNil(TradeMatcher.find(for: sell, in: [stock]))
    }
}

/// 用户 2026-09-03 的**两张真实截图**(IMG_0582 买 / IMG_0583 卖)。
///
/// ★★ 这一组存在的理由是我上一轮**猜错了版式**:
///   用户说「仓位截图……和之前的格式不一样没显示盈亏金额」,
///   我据此以为是「开仓均价 + 平仓均价」那种持仓页,还照着这个猜想写了一整套。
///   拿到真图才知道:<b>版式和以前几乎一样,唯一的区别是少了那行 “+$321.00 return”。</b>
///   而解析器本来就不读那一行 —— 真正的毛病在**后面一步**。
///
/// ★★ 真正的毛病:截图上写着「**Sell to close**」,
///   而库里没有对应的开仓记录时,这一笔被当成**新开的空头** ——
///   于是既不是平仓、也算不出盈亏。
///   券商已经把答案印在图上了,是我一直只取 buy/sell、把 to open / to close 丢了。
final class WealthsimpleSep3Tests: XCTestCase {

    /// IMG_0582:Market buy / Buy to open,10 × $0.26,Total cost $260.00,3:29 pm。
    /// ★★ 这里是**真图跑 Vision 出来的原文**,不是我手抄的。
    ///   手抄版和真 OCR 差了四处,而**每一处都是一个 bug**(见下面的测试)。
    static let buyLines = [
        "15:44  今Z",                       // WiFi/电量图标被认成了汉字
        "个",
        "QQQ Sep 3 $718 Call",
        "$260.00 USD",
        "Account  Day Trading",
        "Status  Completed",
        "Submitted  September 3, 2026",
        "3:29pm",                            // ★ 没有空格
        "Filled  September 3, 2026",
        "3:29pm",
        "Type  Market buy",
        "Buy to open",
        "Time in force  Day order",
        "Entered quantity  10",
        "Filled quantity  10 ×$0.26 USD",   // ★ 乘号是 U+00D7,不是字母 x
        "Total cost  $260.00 USD",
        "View contract details -",
        "View QQQ options",
        "View trade confirmation C",
        "Duplicate order S",
    ]

    /// IMG_0583:Market sell / Sell to close,10 × $0.12,Total value $120.00,3:43 pm。
    /// ★ **没有** “+$xxx return” 那一行 —— 这正是用户说的「和之前的格式不一样」。
    static let sellLines = [
        "15:44  今正",
        "个",
        "QQQ Sep 3 $718 Call",
        "$120.00 USD",
        "Account  Day Trading",
        "Status  Completed",
        "Submitted  September 3, 2026",
        "3:43pm",
        "Filled  September 3, 2026",
        "3:43pm",
        "Type  Market sell",
        "Sell to close",
        "Time in force  Day order",
        "Entered quantity  10",
        "Filled quantity  10 × SO.12 USD",  // ★★ `$0.12` 被认成了 `SO.12`
        "Total value  $120.00 USD",
        "View contract details -",
        "View QQQ options",
        "View trade confirmation C",
    ]

    // ── 解析本身:两张都读得对(这一步以前就是对的,钉住别退化)──

    func testBuyScreenshotParses() {
        let p = ScreenshotParser.parse(lines: Self.buyLines)
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.right?.value, .call)
        XCTAssertEqual(p.strike?.value ?? 0, 718, accuracy: 1e-9)
        XCTAssertEqual(p.side?.value, .buy)
        XCTAssertEqual(p.quantity?.value ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(p.price?.value ?? 0, 0.26, accuracy: 1e-9)
        XCTAssertEqual(p.time?.value.hour, 15, "3:29pm ⇒ 15 点,而不是状态栏的 15:44")
        XCTAssertEqual(p.time?.value.minute, 29)
        XCTAssertEqual(p.intent?.value, .open, "图上写着 Buy to open")
    }

    func testSellScreenshotParses() {
        let p = ScreenshotParser.parse(lines: Self.sellLines)
        XCTAssertEqual(p.side?.value, .sell)
        XCTAssertEqual(p.quantity?.value ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(p.price?.value ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertEqual(p.time?.value.hour, 15, "3:43pm ⇒ 15 点,而不是状态栏的 15:44")
        XCTAssertEqual(p.time?.value.minute, 43)
        XCTAssertEqual(p.intent?.value, .close, "图上写着 Sell to close")
        XCTAssertNil(p.exitPrice, "这是一笔成交,不是持仓页 —— 不该多出一笔平仓")
    }

    // ── 盈亏:两张并成一笔就自己算得出来,不需要截图上印着金额 ──

    /// ★★ 用户那句「理论上软件应该能自己计算出来」的验收:
    ///   买 10 × 0.26 = −$260,卖 10 × 0.12 = +$120 ⇒ **−$140**。
    ///   截图上一个盈亏数字都没有。
    func testPnLIsComputedWithoutAnyReturnLineOnTheScreenshot() {
        XCTAssertFalse(Self.sellLines.contains { $0.lowercased().contains("return") },
                       "前提:这张图上确实没有盈亏金额")

        let buy = ScreenshotParser.parse(lines: Self.buyLines)
        let sell = ScreenshotParser.parse(lines: Self.sellLines)

        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 3
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let expiry = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 718, expiry: expiry))

        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: expiry.addingTimeInterval(-1860),
                 side: buy.side!.value, quantity: buy.quantity!.value, price: buy.price!.value),
        ])
        XCTAssertFalse(t.isClosed)

        // 第二张应当**并进这一笔**,而不是新建
        let m = TradeMatcher.find(for: sell, in: [t])
        XCTAssertNotNil(m, "同一合约、还有 10 张未平 ⇒ 必须匹配上")
        t = TradeMatcher.appendFill(sell, to: t, leg: m!.leg,
                                    at: expiry.addingTimeInterval(-1020))!
        XCTAssertTrue(t.isClosed)
        XCTAssertEqual(t.displayablePnL ?? 0, -140, accuracy: 1e-6)
        XCTAssertEqual(t.returnOnDebit ?? 0, -140.0 / 260.0, accuracy: 1e-9)
    }

    /// ★ 回归:只有平仓那张、库里什么都没有时,**不能**默默当成开空头。
    ///   `intent == .close` 就是判据 —— 券商自己写在图上的。
    func testLoneClosingScreenshotIsRecognisableAsOrphan() {
        let sell = ScreenshotParser.parse(lines: Self.sellLines)
        XCTAssertEqual(sell.intent?.value, .close)
        XCTAssertNil(TradeMatcher.find(for: sell, in: []),
                     "库里没有对应开仓 ⇒ 匹配不上")
        // 界面据这两条一起判:是平仓、又匹配不上 ⇒ 提示用户先导开仓那张
    }

    /// 开仓那张匹配不上是**正常**的(本来就是新仓),不该弹那个提示。
    func testLoneOpeningScreenshotIsNotAnOrphan() {
        let buy = ScreenshotParser.parse(lines: Self.buyLines)
        XCTAssertEqual(buy.intent?.value, .open)
        XCTAssertNil(TradeMatcher.find(for: buy, in: []))
    }
}


/// 真图暴露出来的**四个** OCR 层面的毛病,每个单独钉一条。
///
/// ★★ 这些全都是「合成测试文本永远发现不了」的那一类 ——
///   现有 `WealthsimpleRealTests` 的注释里自己写着:
///   「仍未覆盖:像素级的 OCR 字符错误(0/O、1/l)。那要拿原图跑才知道。」
///   2026-09-03 拿原图跑了,四条全中。
final class RealOCRQuirkTests: XCTestCase {

    /// ① `$0.12` → `SO.12`:`$` 认成 `S`、`0` 认成 `O`。
    func testDollarAndZeroConfusionIsRepaired() {
        XCTAssertEqual(OCRText.fixNumericConfusions("10 × SO.12 USD"), "10 × $0.12 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("O.26"), "0.26")
        XCTAssertEqual(OCRText.fixNumericConfusions("l0"), "10")
    }

    /// ★ 只动看起来是数字的 token —— 别的一个字不许碰。
    func testNonNumericTokensAreLeftAlone() {
        for s in ["USD", "Sell to close", "QQQ Sep 3 $718 Call", "Day order",
                  "Total cost  $260.00 USD", "Options"] {
            XCTAssertEqual(OCRText.fixNumericConfusions(s), s, "不该动:\(s)")
        }
    }

    /// ② 状态栏:OCR 把 WiFi/电量认成汉字之后,只剩「15:44」四个数字,
    ///   旧判据(数字多于 4 个)判不出来 —— 成交时间被读成了手机时间。
    func testStatusBarWithoutBatteryNumbersIsStillStripped() {
        XCTAssertTrue(OCRText.isStatusBar("15:44  今正"))
        XCTAssertTrue(OCRText.isStatusBar("15:44  今Z"))
        XCTAssertTrue(OCRText.isStatusBar("10:56  纳斯...  29172.20  88"))
    }

    /// ★ 合法的成交时间行**不许**被当成状态栏。
    func testRealFillTimeLinesAreNotStatusBars() {
        XCTAssertFalse(OCRText.isStatusBar("10:13 am"))
        XCTAssertFalse(OCRText.isStatusBar("3:43pm"))
        XCTAssertFalse(OCRText.isStatusBar("Filled  10:35 am"))
    }

    /// ③ 「Filled  September 3, 2026」是**日期行**,不是数量行。
    ///   裸 "filled" 当数量标签会把日期里的 3 读成张数。
    func testDateRowIsNotReadAsQuantity() {
        let p = ScreenshotParser.parse(lines: [
            "Filled  September 3, 2026",
            "3:43pm",
            "Type  Market sell",
            "Entered quantity  10",
            "Filled quantity  10 × SO.12 USD",
            "Total value  $120.00 USD",
        ])
        XCTAssertEqual(p.quantity?.value ?? 0, 10, accuracy: 1e-9, "不是 September 里的 3")
    }
}
