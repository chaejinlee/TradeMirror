import XCTest
@testable import ReviewEngine
#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO
#endif

/// **拿真图跑真 OCR** 的那一层。
///
/// ★★ 存在的理由,一句话:<b>手抄的截图文字测的是我的想象,不是现实。</b>
///
///   2026-09-03 用户报「仓位截图没识别成平仓」。当时已经有一份
///   「照抄真图」的测试(`WealthsimpleRealTests`)而且是绿的 ——
///   把原图真跑一遍 Vision 才发现,OCR 吐出来的和我抄的差了四处,
///   <b>每一处都是一个 bug</b>($→S、0→O、`3:43pm` 没空格、
///   WiFi 图标被认成汉字、`Filled` 日期行被当成数量行)。
///
///   同样的教训 `Sanity.swift` 的注释里 09-01 就写过一次
///   (「测试测的是我的转录,不是真实链路」),两天后原样再犯。
///   ⇒ <b>这一层不能靠我记得,得每次构建都由机器跑。</b>
///
/// ★ 断言写得**具体**:不是「解析成功」,而是逐个字段对上真值。
///   「跑通了」和「跑对了」是两回事 —— 这个项目今年已经在这上面栽过四次。
final class RealScreenshotFixtureTests: XCTestCase {

    struct Expectation {
        let file: String
        let symbol: String
        /// ★ 股票/ETF 没有这两项 —— 用 nil 表示「就该是没有」,
        ///   而不是随便填一个值假装它是期权。
        let right: OptionRight?
        let strike: Double?
        let side: Side
        let intent: FillIntent?
        let quantity: Double
        let price: Double
        /// 交易所时区的 HH:mm。★ 必须是**成交时间**,不是手机状态栏的时间。
        let clock: (h: Int, m: Int)
    }

    /// 加新图就往这里加一条,不用改别的。
    static let cases: [Expectation] = [
        // IMG_0582:Market buy / Buy to open,10 × $0.26 @ 3:29 pm
        .init(file: "ws_20260903_buy", symbol: "QQQ", right: .call, strike: 718,
              side: .buy, intent: .open, quantity: 10, price: 0.26, clock: (15, 29)),
        // IMG_0583:Market sell / Sell to close,10 × $0.12 @ 3:43 pm
        // ★ 这张图上 `$0.12` 被 OCR 成 `SO.12`,而且**没有任何盈亏金额**
        .init(file: "ws_20260903_sell", symbol: "QQQ", right: .call, strike: 718,
              side: .sell, intent: .close, quantity: 10, price: 0.12, clock: (15, 43)),

        // ── 2026-09-04 的 8 张(同一天同一张合约,一路加仓再一次平掉)──
        //  ★★ 其中三张原来**认不出成交价**,共同点只有一个:
        //     <b>OCR 把乘号和价格粘在一起</b>(`1×$O.65` / `2 ×$O.32` / `3 ×$O.0733`),
        //     而带空格的那几张都好好的。
        //     旧的 `fixNumericConfusions` 按空格切词,粘住的那一段不像数字 ⇒ 不修 ⇒ 取不出价。
        //     <b>OCR 加不加空格是随机的,而我把它当成了结构。</b>
        .init(file: "ws_20260904_0612", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 3, price: 1.22, clock: (10, 14)),
        .init(file: "ws_20260904_0613", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 1, price: 0.65, clock: (10, 27)),
        .init(file: "ws_20260904_0614", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 2, price: 0.32, clock: (10, 47)),
        .init(file: "ws_20260904_0615", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 10, price: 0.257, clock: (10, 58)),
        .init(file: "ws_20260904_0616", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 5, price: 0.13, clock: (11, 22)),
        .init(file: "ws_20260904_0617", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 9, price: 0.17, clock: (12, 27)),
        .init(file: "ws_20260904_0618", symbol: "QQQ", right: .call, strike: 721,
              side: .buy, intent: .open, quantity: 3, price: 0.0733, clock: (13, 11)),
        .init(file: "ws_20260904_0619", symbol: "QQQ", right: .call, strike: 721,
              side: .sell, intent: .close, quantity: 33, price: 0.03, clock: (13, 31)),

        // ── 2026-09-15 的 4 张:★★ <b>第一次出现 Put</b> ──
        //  前面 10 张全是 Call —— 这正是下面这个 bug 能活下来的原因。
        //
        //  ① 三张 `$705 Put` 被判成 **Call**。原来是「callWords 先判、命中就定案」,
        //     而 callWords 里有 `" c "`;页面按空格连起来之后出现了
        //     `…View trade confirmation C  Duplicate order S…` ——
        //     那个 `C` 是 <b>OCR 把「分享」图标认成的字母</b>。
        //     唯一读对的是卖出那张,只因为它没有 `Duplicate order` 这一行,
        //     `C` 落在末尾、后面没空格。<b>对错取决于页面末尾有没有多一行。</b>
        //  ② 三张的成交价取不出来:`$2,200.00` 被改成 `$2.200.00` ——
        //     逗号被无条件当成小数点。<b>仓位小的时候金额到不了千位,这条永远碰不到。</b>
        //  ③ 0757 的张数读成了 **11** —— 那是状态栏的 `11:40`,
        //     因为 `Filled quantity` 那条路走不通就掉进了通用扫描。
        .init(file: "ws_20260915_0755", symbol: "QQQ", right: .put, strike: 705,
              side: .buy, intent: .open, quantity: 3, price: 1.01, clock: (10, 38)),
        .init(file: "ws_20260915_0756", symbol: "QQQ", right: .put, strike: 705,
              side: .buy, intent: .open, quantity: 20, price: 1.10, clock: (10, 38)),
        .init(file: "ws_20260915_0757", symbol: "QQQ", right: .put, strike: 705,
              side: .buy, intent: .open, quantity: 6, price: 1.84, clock: (10, 52)),
        .init(file: "ws_20260915_0758", symbol: "QQQ", right: .put, strike: 705,
              side: .sell, intent: .close, quantity: 29, price: 1.67, clock: (10, 52)),

        // ── 2026-09-22/23 的 2 张:★★ <b>第一次出现股票</b> ──
        //  前面 14 张全是期权 —— 而用户 2026-09-23 报「这两张放进去没反应」。
        //  股票页和期权页差得很远:标题只有 `BEX`(没有 `Sep 15 $705 Put`)、
        //  数量写 `130 shares` 不是合约、没有开/平仓字样、`Limit buy` 不是 `Market buy`。
        //  ★ 实测结论:<b>解析这一层其实全对</b> —— 但在这两张之前,
        //    <b>没有任何东西能保证它对</b>,因为夹具里一张股票都没有。
        .init(file: "ws_20260922_bex_buy", symbol: "BEX", right: nil, strike: nil,
              side: .buy, intent: nil, quantity: 130, price: 36.91, clock: (15, 20)),
        .init(file: "ws_20260923_bex_sell", symbol: "BEX", right: nil, strike: nil,
              side: .sell, intent: nil, quantity: 130, price: 37.2307, clock: (10, 18)),

        // ── 2026-10-05 的 2 张:SQQQ 来回,★★ <b>第一次出现盘后「24 小时市场」的卖单</b> ──
        //  用户:「报错了」—— 买单认对了,卖单被认成 **1 @ 5**、还标「缺 Call/Put(乘数=100,应该是期权)」。
        //  卖单那页比以往多了两行:`Limit price $32.15 USD`、
        //  `Trading session 24-hour market / Open until end of 24-hour session`。
        .init(file: "ws_20261005_sqqq_buy", symbol: "SQQQ", right: nil, strike: nil,
              side: .buy, intent: nil, quantity: 500, price: 32.2999, clock: (15, 47)),
        .init(file: "ws_20261005_sqqq_sell", symbol: "SQQQ", right: nil, strike: nil,
              side: .sell, intent: nil, quantity: 500, price: 32.1508, clock: (18, 5)),
    ]

    #if canImport(Vision)

    /// 照抄 App 里 `ScreenshotOCR` 的做法:Vision → `LineAssembler` → 文本行。
    /// **两边必须一样**,否则这里测的又不是用户真正走的那条路。
    private func ocrLines(_ name: String) throws -> [String] {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)",
                                          withExtension: "png") else {
            // 公开仓库不含真实券商截图(里面有账户信息)—— 没有夹具就跳过这层 OCR 测试。
            throw XCTSkip("夹具 \(name).png 不在仓库里(真实券商截图不公开),跳过")
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false          // 开着会把 "2.170" 纠正坏
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])

        let blocks = (req.results ?? []).compactMap { o -> LineAssembler.Block? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return LineAssembler.Block(text: t, midY: b.midY, minX: b.minX, height: b.height)
        }
        return LineAssembler.assemble(blocks)
    }

    func testEveryFixtureParsesCorrectlyFromRealOCR() throws {
        for e in Self.cases {
            let lines = try ocrLines(e.file)
            XCTAssertFalse(lines.isEmpty, "\(e.file):OCR 一行都没出来")
            let p = ScreenshotParser.parse(lines: lines)
            let ctx = "\(e.file) · OCR 原文:\n" + lines.joined(separator: "\n")

            XCTAssertEqual(p.symbol?.value, e.symbol, ctx)
            XCTAssertEqual(p.right?.value, e.right, ctx)
            // ★ 股票没有行权价:期望 nil 就必须真的是 nil,不许冒出一个数
            if let k = e.strike {
                XCTAssertEqual(p.strike?.value ?? 0, k, accuracy: 1e-9, ctx)
            } else {
                XCTAssertNil(p.strike?.value, "股票不该有行权价。\(ctx)")
            }
            XCTAssertEqual(p.side?.value, e.side, ctx)
            XCTAssertEqual(p.intent?.value, e.intent, "开/平仓是券商写在图上的,不该丢。\(ctx)")
            XCTAssertEqual(p.quantity?.value ?? 0, e.quantity, accuracy: 1e-9, ctx)
            XCTAssertEqual(p.price?.value ?? 0, e.price, accuracy: 1e-9, ctx)
            XCTAssertEqual(p.time?.value.hour, e.clock.h,
                           "取到的必须是**成交时间**,不是状态栏的手机时间。\(ctx)")
            XCTAssertEqual(p.time?.value.minute, e.clock.m, ctx)
            XCTAssertTrue(p.isUsable, "\(e.file) 判成不可用 —— 用户看到的就是「没识别出来」。\(ctx)")
        }
    }

    /// ★★ 端到端:两张真图 → 两笔成交 → **盈亏是算出来的**。
    ///   这两张图上一个盈亏数字都没有(用户 09-03 原话:「没显示盈亏金额」)。
    func testTwoRealScreenshotsMergeIntoOneTradeWithComputedPnL() throws {
        let buy = ScreenshotParser.parse(lines: try ocrLines("ws_20260903_buy"))
        let sell = ScreenshotParser.parse(lines: try ocrLines("ws_20260903_sell"))

        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 3
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 718, expiry: close))

        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: close.addingTimeInterval(-1860),
                 side: buy.side!.value, quantity: buy.quantity!.value, price: buy.price!.value),
        ])
        let m = try XCTUnwrap(TradeMatcher.find(for: sell, in: [t]),
                              "同一合约、还有 10 张未平 ⇒ 第二张必须并进来,而不是新建一笔")
        t = try XCTUnwrap(TradeMatcher.appendFill(sell, to: t, leg: m.leg,
                                                  at: close.addingTimeInterval(-1020)))

        XCTAssertTrue(t.isClosed)
        XCTAssertEqual(t.displayablePnL ?? 0, -140, accuracy: 1e-6)   // (0.12−0.26)×10×100
        XCTAssertEqual(t.returnOnDebit ?? 0, -140.0 / 260.0, accuracy: 1e-9)
    }

    /// ★★ 端到端:2026-10-05 SQQQ 两张 → **一笔股票** → 盈亏 = 券商自己写的 `−$74.55 return`。
    ///   修之前:卖单认成 1 @ 5、还被当成期权(「缺 Call/Put」)—— 这一笔永远对不上、平不了。
    func testSQQQRoundTripMatchesTheBrokersOwnReturn() throws {
        let buy = ScreenshotParser.parse(lines: try ocrLines("ws_20261005_sqqq_buy"))
        let sell = ScreenshotParser.parse(lines: try ocrLines("ws_20261005_sqqq_sell"))
        XCTAssertNil(buy.right); XCTAssertNil(sell.right)
        XCTAssertFalse(sell.missing.contains { $0.contains("Call/Put") }, "股票不该被要求补 Call/Put")

        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 5
        c.hour = 15; c.minute = 47; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .equity)
        var t = Trade(symbol: "SQQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: buy.side!.value,
                 quantity: buy.quantity!.value, price: buy.price!.value),
        ])
        let m = try XCTUnwrap(TradeMatcher.find(for: sell, in: [t]), "同一只股票、还有 500 股没平 ⇒ 必须并进来")
        t = try XCTUnwrap(TradeMatcher.appendFill(sell, to: t, leg: m.leg, at: t0.addingTimeInterval(8280)))
        XCTAssertTrue(t.isClosed)
        XCTAssertEqual(t.displayablePnL ?? 0, -74.55, accuracy: 0.005)   // 截图上写的 −$74.55 return
    }

    /// ★★ 端到端:2026-09-15 那 4 张 → **一笔 Put** → 盈亏 = 券商自己写的 `+$1,236.00`。
    ///
    ///   ★ 这一笔必须是**一笔**:三张开仓 + 一张平仓,同一个 705 Put。
    ///     Put 判成 Call 时它会被拆成两笔(不同合约当然不合并),
    ///     <b>于是永远平不了、不进统计</b> —— 和 09-04 那次同样的下游后果。
    func testFourPutScreenshotsBecomeOneTradeMatchingTheBrokersOwnPnL() throws {
        let ps = try ["0755", "0756", "0757", "0758"].map {
            ScreenshotParser.parse(lines: try ocrLines("ws_20260915_\($0)"))
        }
        XCTAssertTrue(ps.allSatisfy { $0.right?.value == .put },
                      "四张都是 Put —— 有一张判成 Call,这笔就会被拆开")
        XCTAssertTrue(ps.allSatisfy { $0.isUsable }, "四张都必须可用")

        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 15
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .put, strike: 705, expiry: close))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                      fills: ps.map { p in
            Fill(legID: leg.id, time: close, side: p.side!.value,
                 quantity: p.quantity!.value, price: p.price!.value)
        })

        XCTAssertTrue(t.isClosed, "买 3+20+6 = 29,卖 29 —— 必须正好平完")
        XCTAssertEqual(t.openQuantity, 0, accuracy: 1e-9)
        // 3×1.01 + 20×1.10 + 6×1.84 = 36.07 ⇒ $3,607;卖 29×1.67 = $4,843
        XCTAssertEqual(t.displayablePnL ?? 0, 1236, accuracy: 0.01,
                       "★ 券商自己在图上写着 +$1,236.00 return")
        XCTAssertEqual(t.returnOnDebit ?? 0, 1236.0 / 3607.0, accuracy: 1e-9)
    }

    /// 夹具目录别被误删 —— 少一张图,这层测试就悄悄变成空跑。
    func testFixturesArePresent() throws {
        let missing = Self.cases.filter {
            Bundle.module.url(forResource: "Fixtures/\($0.file)", withExtension: "png") == nil
        }
        // 公开仓库:真实截图整批不入库 → 跳过;只少了几张 → 照样报错(防误删)。
        if missing.count == Self.cases.count {
            throw XCTSkip("真实券商截图不在公开仓库里,跳过夹具检查")
        }
        for e in missing {
            XCTFail("夹具 \(e.file).png 不见了")
        }
    }

    #else

    func testVisionUnavailable() throws {
        throw XCTSkip("这个平台没有 Vision —— 真图 OCR 这层跑不了")
    }

    #endif
}
