import XCTest
@testable import ReviewEngine

/// 截图解析器的测试。
///
/// ⚠️ **这些文本是我按各家券商的常见版式构造的,不是真实 OCR 的输出。**
/// 真实 OCR 会有:字符识别错误(0/O、1/l)、行序错乱、表格被拆成孤立的碎片。
/// 所以**测试全过 ≠ 对真实截图有效** —— 必须拿一张真截图校准。这条写在这里,不许忘。
final class ScreenshotParserTests: XCTestCase {

    // MARK: - moomoo / 富途 中文版式

    func testMoomooChineseOptionFill() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 260806 717 CALL",          // ★ 260806 = 2026-08-06。第一版我写成 250806
            "买入开仓  已成交",             //   却断言 2026 —— 是**测试数据**错了,不是解析器
            "成交数量    2",
            "成交均价    2.170",
            "成交金额    434.00",
            "成交时间    2026/08/06 10:30:15",
        ])
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.side?.value, .buy)
        XCTAssertEqual(p.right?.value, .call)
        XCTAssertEqual(p.strike?.value, 717)
        XCTAssertEqual(p.quantity?.value, 2)
        XCTAssertEqual(p.price?.value, 2.17)
        XCTAssertEqual(p.expiry?.value.year, 2026)
        XCTAssertEqual(p.expiry?.value.month, 8)
        XCTAssertEqual(p.expiry?.value.day, 6)
        XCTAssertEqual(p.time?.value.hour, 10)
        XCTAssertEqual(p.time?.value.minute, 30)
        XCTAssertTrue(p.isUsable)
        XCTAssertTrue(p.missing.isEmpty, "全都认出来了就不该报缺失:\(p.missing)")
    }

    func testMoomooChineseSellClose() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 260806 717 CALL",
            "卖出平仓",
            "成交数量    3",
            "成交均价    2.510",
            "成交时间    2026/08/06 11:02:44",
        ])
        XCTAssertEqual(p.side?.value, .sell)
        XCTAssertEqual(p.quantity?.value, 3)
        XCTAssertEqual(p.price?.value, 2.51)
        XCTAssertEqual(p.time?.value.hour, 11)
    }

    // MARK: - IBKR 紧凑版式

    func testIBKRCompactLine() {
        let p = ScreenshotParser.parse(lines: [
            "BOT 2 QQQ 06AUG26 717 C @ 2.17",
            "Filled  10:30:15 ET",
        ])
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.side?.value, .buy, "BOT = 买入")
        XCTAssertEqual(p.price?.value ?? .nan, 2.17, accuracy: 1e-9)
        XCTAssertEqual(p.expiry?.value.month, 8)
        XCTAssertEqual(p.expiry?.value.day, 6)
        XCTAssertEqual(p.time?.value.hour, 10)
    }

    // MARK: - Robinhood 英文表格版式

    func testRobinhoodTableLayout() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ $717 Call 8/6",
            "Filled",
            "Quantity",
            "2 contracts",
            "Average price",
            "$2.17",
            "Aug 6, 10:30 AM",
        ])
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.right?.value, .call)
        XCTAssertEqual(p.strike?.value, 717)
        XCTAssertEqual(p.price?.value ?? .nan, 2.17, accuracy: 1e-9)
        XCTAssertEqual(p.time?.value.hour, 10)
    }

    // MARK: - 股票(非期权)

    func testPlainStockFill() {
        let p = ScreenshotParser.parse(lines: [
            "TSLA",
            "Sell  Filled",
            "Shares  100",
            "Average price  $250.40",
            "2026/08/31 14:02:00",
        ])
        XCTAssertEqual(p.symbol?.value, "TSLA")
        XCTAssertEqual(p.side?.value, .sell)
        XCTAssertEqual(p.quantity?.value, 100)
        XCTAssertEqual(p.price?.value ?? .nan, 250.40, accuracy: 1e-9)
        XCTAssertNil(p.right, "股票不该被认出 Call/Put")
        XCTAssertTrue(p.isUsable)
    }

    // MARK: - ★ 认不出来的时候必须老实说

    func testUnusableInputReportsMissingInsteadOfGuessing() {
        let p = ScreenshotParser.parse(lines: ["这是一张完全无关的图", "今天天气不错"])
        XCTAssertFalse(p.isUsable, "认不出来就不许说能用")
        XCTAssertTrue(p.missing.contains("成交价"))
        XCTAssertTrue(p.missing.contains("数量"))
        XCTAssertNil(p.price, "宁可返回 nil,也不要编一个数出来")
    }

    func testPartialRecognitionStillReportsWhatIsMissing() {
        let p = ScreenshotParser.parse(lines: ["QQQ 260806 717 CALL", "买入开仓"])
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.side?.value, .buy)
        XCTAssertFalse(p.isUsable, "缺数量和价格,不算可用")
        XCTAssertTrue(p.missing.contains("数量") && p.missing.contains("成交价"))
    }

    /// 置信度必须真的有区分度 —— 全都 0.9 的话这个字段就没意义。
    func testConfidenceDiscriminates() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 260806 717 CALL", "买入开仓",
            "成交数量    2", "成交均价    2.170",
            "10:30",                      // 只有时分,没有日期
        ])
        XCTAssertEqual(p.price?.confidence ?? 0, 0.9, accuracy: 0.01, "带标签同行的数字最可信")
        XCTAssertLessThan(p.time?.confidence ?? 1, 0.7, "只有时分没有日期,置信度必须降下来")
        XCTAssertLessThan(p.strike?.confidence ?? 1, 0.8, "行权价是从标题猜的,不该给高分")
    }

    /// 每个字段都要带出处,用户核对时能对照原图。
    func testEveryFieldCarriesItsSourceLine() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 260806 717 CALL", "买入开仓", "成交数量  2", "成交均价  2.170",
        ])
        XCTAssertTrue(p.price?.source.contains("2.170") ?? false)
        XCTAssertTrue(p.quantity?.source.contains("2") ?? false)
        XCTAssertTrue(p.symbol?.source.contains("QQQ") ?? false)
    }
}

/// 真机崩溃的回归测试(2026-09-01)。
/// 日志原文:`Swift/Range.swift:761: Fatal error: Range requires lowerBound <= upperBound`
/// 原因:在 `lowercased()` 后的串上取 range,却拿去索引原串 —— **两个 String 的 index 不通用**。
final class ParserCrashRegressionTests: XCTestCase {

    /// 解析器**在任何输入下都不许崩**。用户会喂进来各种奇怪的图。
    func testNeverCrashesOnHostileInput() {
        let hostile: [[String]] = [
            [],
            [""],
            ["İSTANBUL 成交均价 2.17"],            // 土耳其 İ 小写后会变长 —— 就是崩溃那一类
            ["ﬁ ﬂ ǅ Ǆ 成交数量 3"],                 // 连字/钛字,小写化改变长度
            ["成交时间 2026/08"],                   // 日期分量不足 3 个
            ["价格", "均价", "@", "@@@@"],
            [String(repeating: "成交均价 ", count: 200)],
            ["\u{1F600}\u{1F4C8} QQQ 买入 2 @ 2.17"], // emoji
            ["ＱＱＱ　成交均价　２.１７"],              // 全角
        ]
        for lines in hostile {
            _ = ScreenshotParser.parse(lines: lines)   // 不崩就算过
        }
    }

    /// 大小写混排的标签仍要认得出来(改用 caseInsensitive 查找之后的行为)。
    func testCaseInsensitiveLabels() {
        let p = ScreenshotParser.parse(lines: [
            "AAPL", "SELL  FILLED", "QUANTITY  50", "AVERAGE PRICE  $180.25",
        ])
        XCTAssertEqual(p.symbol?.value, "AAPL")
        XCTAssertEqual(p.side?.value, .sell)
        XCTAssertEqual(p.quantity?.value, 50)
        XCTAssertEqual(p.price?.value ?? .nan, 180.25, accuracy: 1e-9)
    }
}

/// 分行器的测试。数据来自**真实 OCR 输出**(2026-09-01 对合成 moomoo 截图跑 Vision 得到的坐标),
/// 不是我编的 —— 这也是为什么值的 midY 会比标签高 0.0008 这种细节能被覆盖到。
final class LineAssemblerTests: XCTestCase {

    /// 真实坐标:值在左标签之前(midY 高 0.0008),必须被拼回同一行。
    func testValueAndLabelOnSameVisualRowGetJoined() {
        let b = [
            LineAssembler.Block(text: "2",        midY: 0.8285, minX: 0.9291, height: 0.020),
            LineAssembler.Block(text: "成交数量",  midY: 0.8277, minX: 0.0506, height: 0.020),
            LineAssembler.Block(text: "2.170",    midY: 0.7718, minX: 0.8631, height: 0.020),
            LineAssembler.Block(text: "成交均价",  midY: 0.7717, minX: 0.0506, height: 0.020),
        ]
        let lines = LineAssembler.assemble(b)
        XCTAssertEqual(lines.count, 2, "四个文本块应拼成两行")
        XCTAssertTrue(lines[0].hasPrefix("成交数量"), "组内要按 X 从左到右:\(lines[0])")
        XCTAssertTrue(lines[0].contains("2"))
        XCTAssertTrue(lines[1].hasPrefix("成交均价"))
        XCTAssertTrue(lines[1].contains("2.170"))
    }

    /// ★ 端到端:真实 OCR 坐标 → 分行 → 解析,张数和成交价不许串位。
    func testRealOCRLayoutParsesCorrectly() {
        let b: [(String, Double, Double)] = [
            ("QQQ 260806 717 CALL", 0.9295, 0.0506),
            ("已成交",               0.8903, 0.2505),
            ("买入开仓",             0.8895, 0.0504),
            ("2",                   0.8285, 0.9291),
            ("成交数量",             0.8277, 0.0506),
            ("2.170",               0.7718, 0.8631),
            ("成交均价",             0.7717, 0.0506),
            ("434.00",              0.7151, 0.8455),
            ("成交金额",             0.7151, 0.0505),
            ("1.30",                0.6598, 0.8810),
            ("手续费",               0.6591, 0.0506),
            ("2026/08/06 10:30:15", 0.6038, 0.6380),
            ("成交时间",             0.6032, 0.0506),
        ]
        let lines = LineAssembler.assemble(b.map {
            LineAssembler.Block(text: $0.0, midY: $0.1, minX: $0.2, height: 0.020) })
        let p = ScreenshotParser.parse(lines: lines)
        XCTAssertEqual(p.quantity?.value, 2,    "★ 这就是那个 bug:张数曾被读成 2.170")
        XCTAssertEqual(p.price?.value ?? .nan, 2.17, accuracy: 1e-9)
        XCTAssertEqual(p.symbol?.value, "QQQ")
        XCTAssertEqual(p.side?.value, .buy)
        XCTAssertEqual(p.right?.value, .call)
        XCTAssertEqual(p.strike?.value, 717)
        XCTAssertEqual(p.time?.value.hour, 10)
        XCTAssertEqual(p.time?.value.minute, 30)
        XCTAssertTrue(p.isUsable)
        XCTAssertTrue(p.missing.isEmpty, "不该再报缺失:\(p.missing)")
    }

    /// 行距太近时不许把两行并成一行(容差不能设太大)。
    func testTightlyPackedRowsStaySeparate() {
        let b = [
            LineAssembler.Block(text: "A", midY: 0.500, minX: 0.1, height: 0.010),
            LineAssembler.Block(text: "B", midY: 0.488, minX: 0.1, height: 0.010),
        ]
        XCTAssertEqual(LineAssembler.assemble(b).count, 2)
    }
}

/// 算术恒等式交叉验证。**这是「支持所有券商」的真正答案** ——
/// 标签是每家一套,但 `张数 × 价格 × 乘数 = 金额` 这个关系是普适的。
final class NumericSolverTests: XCTestCase {

    func testClosesTheIdentityForOptions() {
        let c = NumericSolver.solve(numbers: [2, 2.17, 434.00, 1.30])
        XCTAssertEqual(c.first?.quantity, 2)
        XCTAssertEqual(c.first?.price ?? .nan, 2.17, accuracy: 1e-9)
        XCTAssertEqual(c.first?.multiplier, 100)
        XCTAssertGreaterThan(c.first?.confidence ?? 0, 0.9)
    }

    func testClosesTheIdentityForStocks() {
        let c = NumericSolver.solve(numbers: [100, 250.40, 25040.00])
        XCTAssertEqual(c.first?.quantity, 100)
        XCTAssertEqual(c.first?.price ?? .nan, 250.40, accuracy: 1e-9)
        XCTAssertEqual(c.first?.multiplier, 1)
    }

    /// ★★ 决定性的一条:**标签完全不认识**(随便一种没见过的语言/版式),
    /// 只靠数字之间的关系仍然要定得出张数和价格。
    func testWorksWithCompletelyUnknownLabels() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 260806 717 CALL",
            "Kauf  Eröffnung",              // 德语,词表里没有
            "Stückzahl        3",
            "Durchschnittspreis  2.510",
            "Gesamtbetrag     753.00",
        ])
        XCTAssertEqual(p.quantity?.value, 3, "标签一个都不认识,但 3 × 2.51 × 100 = 753 闭合")
        XCTAssertEqual(p.price?.value ?? .nan, 2.51, accuracy: 1e-9)
        XCTAssertGreaterThan(p.quantity?.confidence ?? 0, 0.9)
        XCTAssertTrue(p.quantity?.source.contains("算术校验") ?? false)
    }

    /// 标签认对时,两条独立证据一致 → 置信度拉满。
    func testAgreementBetweenLabelAndArithmeticBoostsConfidence() {
        let p = ScreenshotParser.parse(lines: [
            "QQQ 260806 717 CALL", "买入开仓",
            "成交数量  2", "成交均价  2.170", "成交金额  434.00",
        ])
        XCTAssertEqual(p.quantity?.confidence ?? 0, 0.98, accuracy: 0.001)
        XCTAssertEqual(p.price?.confidence ?? 0, 0.98, accuracy: 0.001)
    }

    /// 手续费之类的数不该被误当成金额闭合。
    func testFeeDoesNotCreateFalseIdentity() {
        let c = NumericSolver.solve(numbers: [1.30, 0.65, 2.60])   // 全是小额,凑不出合理张数
        XCTAssertTrue(c.allSatisfy { $0.quantity >= 1 && $0.quantity == $0.quantity.rounded() })
    }

    /// 订单号、日期、百分比不许进候选集 —— 否则会凑出假的恒等式。
    func testNoisyNumbersAreFilteredOut() {
        let ns = NumericSolver.extractNumbers(from: [
            "订单号 1258403917", "成交时间 2026/08/06 10:30:15",
            "涨跌幅 -1.34%", "成交数量 2", "成交均价 2.170", "成交金额 434.00",
        ])
        XCTAssertFalse(ns.contains(1258403917), "订单号不该进来")
        XCTAssertFalse(ns.contains(2026), "日期分量不该进来")
        XCTAssertFalse(ns.contains(-1.34), "百分比不该进来")
        XCTAssertTrue(ns.contains(2) && ns.contains(2.17) && ns.contains(434))
    }
}

/// 2026-10-05 SQQQ 那两张:「报错了」—— 卖单认成 1 @ 5、还说「缺 Call/Put(乘数=100,应该是期权)」。
/// ★ 真图夹具(`RealScreenshotFixtureTests`)里这几条修复**互相兜底**:撤掉任何一条,两张图照样对 ——
///   所以每一条都得有自己的测试,不然以后坏了一条,没人知道兜底只剩下另外几条了。
final class SQQQRegressionTests: XCTestCase {

    /// ① 取数时剔掉英文日期、不带空格的 `3:47pm`、灵动岛计时器 —— 那天的 1、3、5、15 都是从这三处漏进来的。
    func testExtractNumbersDropsDatesTimesAndTimers() {
        let xs = NumericSolver.extractNumbers(from: [
            "1小时15分钟", "Submitted  October 5, 2026", "3:47pm", "Filled  Oct 5, 2026", "6:05 pm",
            "Timer 1 hr 15 min", "Filled quantity  500 shares x $32.2999 USD",
        ])
        XCTAssertEqual(xs, [500, 32.2999])
    }

    /// ② 浮点噪声当 0 —— **卖单**就是死在这一条:500 × 32.1508 算出来是 16075.399999999998,
    ///   误差 1.1e-16,排在了恰好为 0 的巧合「1 × 5 × 100 = 500」后面。
    func testFloatNoiseIsTreatedAsExact() throws {
        XCTAssertNotEqual(500 * 32.1508, 16075.40, "夹具本身:这一组必须带着浮点误差")
        let best = try XCTUnwrap(NumericSolver.solve(numbers: [1, 5, 500, 32.1508, 16075.40]).first)
        XCTAssertEqual(best.quantity, 500)
        XCTAssertEqual(best.price, 32.1508)
        XCTAssertEqual(best.multiplier, 1)
    }

    /// ③ 同误差、同乘数时金额大的优先 —— **买单**死在这一条:500 × 32.2999 正好等于 16149.95,
    ///   可「3 × 5 = 15」也正好闭合,按迭代顺序排在前面。
    func testBiggerNotionalBreaksAnExactTie() throws {
        XCTAssertEqual(500 * 32.2999, 16149.95, "夹具本身:这一组必须精确闭合")
        let best = try XCTUnwrap(NumericSolver.solve(numbers: [3, 5, 15, 500, 32.2999, 16149.95],
                                                     multipliers: [1]).first)
        XCTAssertEqual(best.quantity, 500)
        XCTAssertEqual(best.price, 32.2999)
    }

    /// ④ 标签和某一组**精确**闭合的算术一致 ⇒ 就是它,哪怕排在前面的是另一组巧合。
    func testLabelsThatCloseExactlyBeatACoincidence() throws {
        // 真:10 × 20 = 200;巧合:4 × 50 = 200(同金额、同乘数,按迭代顺序会排在前面)
        let p = ScreenshotParser.parse(lines: [
            "XYZ", "买入", "成交数量 10", "成交价 20.00", "成交金额 200.00", "手续费 4", "积分 50",
        ])
        XCTAssertEqual(p.quantity?.value, 10)
        XCTAssertEqual(p.price?.value, 20)
    }

    /// ⑤ 限价不是成交价:`Limit price $32.15` 不许当成交价,也不许让成交价被标成「冲突」。
    func testLimitPriceIsNotTheFillPrice() throws {
        let p = ScreenshotParser.parse(lines: [
            "SQQQ", "$16,075.40 USD", "Filled  October 5, 2026", "6:05 pm", "Type  Limit sell",
            "Limit price  $32.15 USD", "Entered quantity  500 shares",
            "Filled quantity  500 shares x $32.1508 USD", "Total value  $16,075.40 USD",
        ])
        XCTAssertEqual(p.quantity?.value, 500)
        XCTAssertEqual(try XCTUnwrap(p.price?.value), 32.1508, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(p.price?.confidence), 0.9, "不该被标成两边冲突")
        XCTAssertNil(p.right)
        XCTAssertFalse(p.missing.contains { $0.contains("Call/Put") }, "股票不该被要求补 Call/Put")
    }
}

