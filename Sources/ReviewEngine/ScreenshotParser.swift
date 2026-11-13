import Foundation

/// 从券商截图的 **OCR 文本行** 解析出一笔交易的草稿。
///
/// ★ 设计前提:**用户一定会二次确认。**
/// 所以解析器的目标不是「猜对」,是「给一份好草稿 + 老实说明哪些没把握」。
/// 每个字段都带 `confidence`,界面据此决定是否高亮提醒用户核对。
///
/// ★ 分层:**这里只吃字符串,不碰图片。** OCR(Vision)在 App 层做。
/// 这样解析逻辑可以用纯文本写测试,不需要准备图片资源。
public struct ParsedField<T>: Sendable where T: Sendable {
    public var value: T
    /// 0…1。**低于 0.6 的一律在界面上标出来让用户核对。**
    public var confidence: Double
    /// 从哪一行认出来的 —— 用户核对时能对照原图。
    public var source: String
    public init(_ v: T, _ c: Double, _ s: String) { value = v; confidence = c; source = s }
}

/// 这一笔是**开仓**还是**平仓**。
///
/// ★★ 2026-09-03:用户的两张真实截图上,券商**明明白白写着**
///   「Buy to open」和「Sell to close」——<b>而我一直只取了 buy/sell,
///   把 to open / to close 整个丢掉了。</b>
///   丢掉的后果:一张「Sell to close」在没有对应开仓记录时,
///   会被当成**开了一个空头**,于是既不是平仓、也没有盈亏。
///   这条信息是券商给的事实,不用猜。
public enum FillIntent: String, Sendable, Equatable { case open, close }

public struct ParsedTrade: Sendable {
    public var symbol: ParsedField<String>?
    public var right: ParsedField<OptionRight>?
    public var strike: ParsedField<Double>?
    public var expiry: ParsedField<DateComponents>?
    public var side: ParsedField<Side>?
    /// 开仓 / 平仓。截图上写着就取,写着才取。
    public var intent: ParsedField<FillIntent>?
    public var quantity: ParsedField<Double>?
    public var price: ParsedField<Double>?
    /// **仓位截图**里的平仓均价。v3.4 新增。
    ///
    /// ★★ 用户 2026-09-03:「我放了仓位截图进去,软件没识别出来是平仓订单……
    ///   但是理论上软件应该能自己计算出来」。
    ///   成交明细截图是**一笔**成交;仓位截图往往同时写着**开仓均价和平仓均价** ——
    ///   两个价都在,这笔就是完整的一来一回,<b>盈亏根本不用截图告诉我们,自己就能算</b>。
    ///   ⇒ 认出这一对时,草稿直接给**两笔成交**(开 + 平)。
    /// ★ 只有一个价时**不许**臆造出一笔平仓 —— 那就是普通的成交均价。
    public var exitPrice: ParsedField<Double>?
    public var time: ParsedField<DateComponents>?
    /// 没认出来的字段名,直接告诉用户「这些要你自己填」。
    public var missing: [String] = []
    /// 整体是否值得用。任何一个核心字段缺失就为 false。
    public var isUsable: Bool { symbol != nil && quantity != nil && price != nil && side != nil }
}

public enum ScreenshotParser {

    // 常见券商的措辞。中英混排,大小写不敏感。
    //
    // ★★ 2026-09-03 实测的 bug:原来是「先找 buyWords,找到就定案」。
    //   而仓位截图上「开仓均价」和「平仓均价」**同时存在** ——
    //   `开仓` 命中在前,于是一张平仓截图被判成买入,
    //   合并时变成**加仓**而不是平仓,<b>盈亏当然算不出来</b>。
    //   两个毛病叠在一起:① 买字优先 ② 把 `开仓均价` 这种**字段名**当成了动作。
    //   ⇒ 改成:两边各自计分,取高的;字段名(后面跟着「价/均价/成本/数量…」)不算动作。
    private struct SideWord { let w: String; let side: Side; let weight: Double }
    private static let sideWords: [SideWord] = [
        // 强证据:这就是**动作**本身
        .init(w: "买入", side: .buy, weight: 1.0),
        .init(w: "买进", side: .buy, weight: 1.0),
        .init(w: "买单", side: .buy, weight: 1.0),
        .init(w: "bought", side: .buy, weight: 1.0),
        .init(w: "bot", side: .buy, weight: 1.0),
        .init(w: "卖出", side: .sell, weight: 1.0),
        .init(w: "卖平", side: .sell, weight: 1.0),
        .init(w: "卖单", side: .sell, weight: 1.0),
        .init(w: "平仓", side: .sell, weight: 1.0),
        .init(w: "sold", side: .sell, weight: 1.0),
        .init(w: "sld", side: .sell, weight: 1.0),
        .init(w: "buy", side: .buy, weight: 0.9),
        .init(w: "sell", side: .sell, weight: 0.9),
        // 弱证据:也可能只是在描述持仓,不是这一单的动作
        .init(w: "开仓", side: .buy, weight: 0.35),
        .init(w: "long", side: .buy, weight: 0.3),
        .init(w: "short", side: .sell, weight: 0.3),
        .init(w: "close", side: .sell, weight: 0.3),
    ]

    /// 紧跟在词后面的这些字说明它是**字段名**,不是动作:
    /// 「开仓均价」「平仓价」「持仓数量」「close price」。
    private static let labelSuffixes = ["价", "均价", "成本", "数量", "量", "额", "费", "日", "时间",
                                        " price", " cost", " qty", " avg", " time", " date"]

    /// 这一处出现是「动作」还是「字段名」。
    private static func isLabelUsage(_ line: String, after r: Range<String.Index>) -> Bool {
        let tail = String(line[r.upperBound...]).lowercased()
        return labelSuffixes.contains { tail.hasPrefix($0) }
    }

    /// 把空格全抽掉再比。
    ///
    /// ★★ 2026-09-23:系统升级(Darwin 25 → 27)换了 Vision 的模型,
    ///   同一张图上 <code>Buy to open</code> 变成了 <code>Buy toopen</code> ——
    ///   <b>三张已经绿了几周的夹具当场变红,而我一行代码都没改。</b>
    ///
    /// ★★ 这和 2026-09-04 那个「乘号粘着价格」是**同一句话**:
    ///   <b>OCR 加不加空格是随机的,而我把它当成了结构。</b>
    ///   当时我只把这条教训用在了**数字**那一路(`fixNumericConfusions`),
    ///   <b>词匹配这一路原样留着</b> —— 于是同一个坑在三周后被一次系统升级重新踩开。
    ///
    /// ★ 只对**纯 ASCII 关键词**做这件事:中文词本来就不带空格,
    ///   而抽掉空格会把「卖 出」这种误判进来。
    static func containsIgnoringSpaces(_ line: String, _ word: String) -> Bool {
        guard word.allSatisfy({ $0.isASCII }) else {
            return line.range(of: word, options: .caseInsensitive) != nil
        }
        let squeeze = { (t: String) in t.filter { !$0.isWhitespace }.lowercased() }
        return squeeze(line).contains(squeeze(word))
    }
    /// Call / Put 的证据,**带权重**。
    ///
    /// ★★ 2026-09-15 用户 4 张真图,3 张把 `$705 Put` 判成了 Call。
    ///   原来是「callWords 先判,命中就定案」,而 callWords 里有 `" c "` ——
    ///   页面按空格连起来之后出现了这么一段:
    ///   <code>…View QQQ options  View trade confirmation C  Duplicate order S…</code>
    ///   那个 `C` 是 <b>OCR 把「分享」图标认成的字母</b>,后面正好跟一个空格。
    ///   ⇒ 一个图标战胜了标题里明写着的 `Put`。
    ///
    ///   唯一读对的是卖出那张 —— 因为它**没有 `Duplicate order` 这一行**,
    ///   `confirmation C` 是最后一行,后面没有空格,`" c "` 就不匹配了。
    ///   <b>对错取决于页面末尾有没有多一行,这不叫判断,这叫巧合。</b>
    ///
    /// ★ 这和 09-03 那个「买字优先 + 把字段名当成动作」是同一个形状,
    ///   那次的解法(两边各自计分、取高的)当时只用在了 `judgeSide` 上 ——
    ///   <b>同一个教训没有铺到隔壁那三行。</b>
    private static let rightWords: [(w: String, r: OptionRight, weight: Double)] = [
        // 明写出来的词:最硬的证据
        ("call", .call, 0.9), ("看涨", .call, 0.9), ("认购", .call, 0.9),
        ("put",  .put,  0.9), ("看跌", .put,  0.9), ("认沽", .put,  0.9),
        ("购", .call, 0.5), ("沽", .put, 0.5),
    ]

    /// 贴在数字后面的单字母:`705C` / `705 C` / `$705C`。
    /// ★ 必须**紧跟行权价**才算 —— 孤零零一个字母只可能是图标或噪声。
    private static let RIGHT_SUFFIX = #"\d\s?([CPcp])\b"#

    /// 主入口。`lines` 是 OCR 出来的文本行,**顺序应与图上从上到下一致**。
    public static func parse(lines rawLines: [String], now: Date = Date()) -> ParsedTrade {
        // ★ 先修 OCR 在数字里的混淆($→S、0→O),再去状态栏。
        //   顺序无所谓,但**必须在取数之前** —— 真图上就是这一步救回了成交价。
        let lines = OCRText.stripStatusBar(
            rawLines.map { OCRText.fixNumericConfusions($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty })
        let all = lines.joined(separator: " \n ")
        let low = all.lowercased()
        var out = ParsedTrade()

        // ── 标的:1-5 个大写字母,且不是常见噪声词 ──
        let noise: Set<String> = ["CALL", "PUT", "BUY", "SELL", "BOT", "SLD", "USD", "GTC",
                                  "DAY", "OPG", "LMT", "MKT", "FILLED", "OPEN", "CLOSE", "AM", "PM",
                                  "ET", "EST", "EDT", "P", "L", "C", "S", "QTY", "AVG", "NEW"]
        // ★ 要扫**一行里的所有**大写词,不能只看第一个 ——
        //   「BOT 2 QQQ 06AUG26 …」的第一个是噪声词 BOT,只看第一个会把整行跳过。
        outer: for (i, ln) in lines.enumerated() {
            for sym in matches(ln, #"\b[A-Z]{1,5}\b"#) {
                if noise.contains(sym) || sym.count == 1 { continue }
                out.symbol = ParsedField(sym, i < 3 ? 0.9 : 0.65, ln)
                break outer
            }
        }

        // ── 方向:两边各自计分,取高的 ──
        out.side = judgeSide(lines)

        // ── 开仓 / 平仓:★ 券商写在图上了,直接取 ──
        //   「开仓均价」这种字段名不算(和方向判定共用同一个排除规则)。
        out.intent = judgeIntent(lines)

        // ── Call / Put:**两边各自计分,取高的** ──
        out.right = judgeRight(lines)

        // ── ★★ 仓位截图:开仓均价 + 平仓均价**同时存在** ⇒ 这是完整的一来一回 ──
        //   盈亏不用截图告诉我们,两个价一摆出来自己就算得出来。
        //   只有一个价时不当成对 —— 那就是普通的成交均价。
        if let entry = labeled(lines, entryPriceLabels),
           let exit = labeled(lines, exitPriceLabels) {
            out.price = entry
            out.exitPrice = exit
            // 「方向」在这里指的是**开仓那一边**:多头 = 买入开仓。
            // ★ 没有明确的做空标记就按多头,但**信心压低、写进 missing**,
            //   让界面把它高亮出来 —— 做空时算出来的盈亏是反的,不能悄悄默认。
            // ★ 同一条教训铺过来:多词标记也可能被 OCR 吃掉空格
            //   (`sell to open` → `sell toopen`)。见 `containsIgnoringSpaces`。
            let isShort = shortMarkers.contains { containsIgnoringSpaces(low, $0) }
            out.side = ParsedField(isShort ? .sell : .buy, isShort ? 0.85 : 0.55,
                                   isShort ? (lineContaining(lines, "空") ?? entry.source) : entry.source)
        }

        // ── 带标签的数值:「成交均价 2.170」「Avg price $2.17」 ──
        // ★ 2026-10-05:`Limit price $32.15 USD` 是**下单时设的限价**,不是成交价 ——
        //   成交价在 `Filled quantity 500 shares x $32.1508 USD` 那一行。
        //   原来裸的 "price" 先撞上限价那一行,算术再把它改成 32.1508,还标成「两边冲突、请核对」。
        //   ⇒ 限价 / 止损价 / 触发价这些订单参数行,不拿来找成交价。
        if out.price == nil {
        out.price = labeled(lines.filter { !isOrderParameter($0) },
                            ["成交均价", "成交价", "均价", "avg price", "average price",
                             "avg fill", "fill price", "price", "@"])
        }
        out.quantity = labeled(lines, ["成交数量", "成交量", "持仓数量", "持仓量", "数量",
                                       "quantity", "qty", "position size",
                                       // ★ 不要裸的 "filled":真图里「Filled  September 3, 2026」
                                       //   是**成交时间**那一行,裸匹配会把日期里的 3 当成张数。
                                       "filled quantity", "contracts", "shares", "股数", "张数"])
        // 行权价:通常紧跟标的,且是较大的整数
        out.strike = labeled(lines, ["行权价", "strike"])
            ?? strikeFromHeader(lines)

        // ── 日期与时间 ──
        out.time = timestamp(lines)
        out.expiry = expiryFromHeader(lines)

        // ── ★ 算术恒等式交叉验证(与语言/版式/券商无关)──
        //   张数 × 成交价 × 乘数 = 成交金额。等式一闭合,谁是谁就定了。
        //   这一层的作用有三个:① 标签认错时纠正它 ② 标签认不出时兜底
        //   ③ 标签认对时把置信度拉满(两条独立证据互相印证)
        let mults: [Double] = out.right != nil ? [100] : [1, 100]
        let solved = NumericSolver.solve(
            numbers: NumericSolver.extractNumbers(from: lines), multipliers: mults)
        // ★★ 2026-10-05:**先找和标签完全一致的那一组。** 有 ⇒ 两条证据互相印证,就是它;
        //   没有 ⇒ 才拿算术最好的那组去纠正标签。
        //   原来是「算术排第一的那组和标签不一致 ⇒ 以算术为准」—— 而页面上能凑出好几组恰好闭合的,
        //   SQQQ 卖单上标签明明白白写着 `500 shares x $32.1508`,被「1 × 5 × 100 = 500」改成了 1 @ 5。
        //   ⚠️ 必须是**精确**闭合:Limit price $32.15 × 500 = 16,075.00 和真金额 16,075.40 只差 2.5e-5,
        //      在 2% 容差之内 —— 宽松地「一致」就会把限价当成成交价确认下来。
        let agreeing = solved.first { c in
            c.relativeError < 1e-6
                && out.quantity.map { abs($0.value - c.quantity) < 1e-6 } == true
                && out.price.map { abs($0.value - c.price) < 1e-6 } == true
        }
        if let best = agreeing ?? solved.first, best.confidence >= 0.6 {
            let qMatch = out.quantity.map { abs($0.value - best.quantity) < 1e-6 } ?? false
            let pMatch = out.price.map    { abs($0.value - best.price)    < 1e-6 } ?? false
            let note = "算术校验:\(best.quantity.cleanNum) × \(best.price) × "
                     + "\(best.multiplier.cleanNum) = \(best.notional.cleanNum)"

            if out.quantity == nil || !qMatch {
                // 标签没认出来,或认出来的与算术冲突 —— **以算术为准**,但冲突时降信心让用户核对
                out.quantity = ParsedField(best.quantity,
                                           out.quantity == nil ? best.confidence : 0.65, note)
            } else {
                out.quantity = ParsedField(best.quantity, 0.98, note)   // 两条证据一致
            }
            // ★ 仓位截图有两个价,「张数 × 价 × 乘数 = 金额」解出来的多半是市值或
            //   某一边的金额 —— 让它覆盖会把开仓价改成别的数。标签在这种情况更可信。
            if out.exitPrice == nil {
                if out.price == nil || !pMatch {
                    out.price = ParsedField(best.price,
                                            out.price == nil ? best.confidence : 0.65, note)
                } else {
                    out.price = ParsedField(best.price, 0.98, note)
                }
            }
            // 乘数 100 闭合 ⇒ 这多半是期权。标签没认出 Call/Put 时至少能提示。
            if best.multiplier == 100, out.right == nil {
                out.missing.append("Call/Put(算术显示乘数=100,应该是期权)")
            }
        }

        // ── 缺什么直接说 ──
        if out.symbol == nil   { out.missing.append("标的") }
        if out.side == nil     { out.missing.append("买/卖") }
        if out.quantity == nil { out.missing.append("数量") }
        if out.price == nil    { out.missing.append("成交价") }
        if out.right != nil && out.strike == nil { out.missing.append("行权价") }
        if out.time == nil     { out.missing.append("成交时间") }
        return out
    }

    /// 方向判定。**不再是「先找到谁算谁」** —— 两边各自计分,取高的;
    /// 分数接近(都有证据、分不出)时返回 nil,由界面问用户。
    /// Call 还是 Put。**两边各自计分,取高的** —— 和 `judgeSide` 同一套办法。
    ///
    /// ★ 势均力敌就**不猜**:宁可让界面问一句,也不要把 Put 记成 Call ——
    ///   方向记反的一笔,盈亏、反事实、纪律统计全是反的,而且看不出来。
    static func judgeRight(_ lines: [String]) -> ParsedField<OptionRight>? {
        var score: [OptionRight: Double] = [.call: 0, .put: 0]
        var source: [OptionRight: String] = [:]

        func bump(_ r: OptionRight, _ w: Double, _ ln: String) {
            if w > (score[r] ?? 0) { score[r] = w; source[r] = ln }
        }

        for ln in lines {
            for rw in rightWords where ln.range(of: rw.w, options: .caseInsensitive) != nil {
                bump(rw.r, rw.weight, ln)
            }
            // 贴着行权价的单字母:`705C`。权重低于明写的词,但比图标可信。
            var from = ln.startIndex
            while let m = ln.range(of: RIGHT_SUFFIX, options: .regularExpression,
                                   range: from..<ln.endIndex) {
                from = m.upperBound
                let ch = ln[m].last.map { Character($0.lowercased()) }
                if ch == "c" { bump(.call, 0.7, ln) } else if ch == "p" { bump(.put, 0.7, ln) }
            }
        }

        let c = score[.call] ?? 0, p = score[.put] ?? 0
        guard max(c, p) > 0 else { return nil }
        // ★ 差得太少就不猜 —— 同一张图上两种证据都有,多半是我看错了某一处
        guard abs(c - p) > 0.15 else { return nil }
        let win: OptionRight = c > p ? .call : .put
        return ParsedField(win, min(0.9, max(c, p)), source[win] ?? "")
    }

    static func judgeSide(_ lines: [String]) -> ParsedField<Side>? {
        var score: [Side: Double] = [.buy: 0, .sell: 0]
        var source: [Side: String] = [:]
        for ln in lines {
            for sw in sideWords {
                var from = ln.startIndex
                while let r = ln.range(of: sw.w, options: [.caseInsensitive], range: from..<ln.endIndex) {
                    from = r.upperBound
                    guard !isLabelUsage(ln, after: r) else { continue }   // 字段名,不算动作
                    if sw.weight > (score[sw.side] ?? 0) {
                        score[sw.side] = sw.weight
                        source[sw.side] = ln
                    }
                }
            }
        }
        let b = score[.buy] ?? 0, s = score[.sell] ?? 0
        guard max(b, s) > 0 else { return nil }
        // ★ 势均力敌 ⇒ **不猜**。宁可让界面问一句,也不要把平仓记成加仓。
        guard abs(b - s) > 0.2 else { return nil }
        let win: Side = b > s ? .buy : .sell
        return ParsedField(win, min(0.9, max(b, s)), source[win] ?? "")
    }

    /// 开仓 / 平仓。**只认截图上写着的**,写着才给,不写就是 nil。
    static func judgeIntent(_ lines: [String]) -> ParsedField<FillIntent>? {
        for ln in lines {
            for (words, v) in [(closeWords, FillIntent.close), (openWords, FillIntent.open)] {
                for w in words {
                    // ★★ 先按原样找(能拿到位置,才能排除「开仓均价」这种字段名);
                    //   找不到时再**抽掉空格**找一遍 —— 见 `containsIgnoringSpaces`。
                    if ln.range(of: w, options: .caseInsensitive) == nil,
                       containsIgnoringSpaces(ln, w) {
                        return ParsedField(v, 0.9, ln)
                    }
                    var from = ln.startIndex
                    while let r = ln.range(of: w, options: [.caseInsensitive],
                                           range: from..<ln.endIndex) {
                        from = r.upperBound
                        guard !isLabelUsage(ln, after: r) else { continue }
                        return ParsedField(v, 0.95, ln)
                    }
                }
            }
        }
        return nil
    }

    /// 仓位截图里的「开仓均价 + 平仓均价」。**两个都在**才算一对。
    private static let entryPriceLabels = ["开仓均价", "开仓价", "建仓均价", "持仓均价",
                                           "成本价", "开仓成本", "avg cost", "average cost",
                                           "cost basis", "open price", "avg open", "entry price"]
    private static let exitPriceLabels  = ["平仓均价", "平仓价", "清仓均价", "close price",
                                           "closing price", "avg close", "exit price", "avg exit"]
    /// 开平仓意图。**券商自己印在图上的字**,不用推断。
    private static let openWords  = ["buy to open", "sell to open", "to open",
                                     "开仓", "bto", "sto"]
    private static let closeWords = ["sell to close", "buy to close", "to close",
                                     "平仓", "stc", "btc"]

    /// 明确说了是做空的标记 —— 有它才敢把开仓当成卖出。
    private static let shortMarkers = ["空头", "看空", "卖出开仓", "sell to open", "short position"]

    // MARK: - 私有

    private static func lineContaining(_ lines: [String], _ needle: String) -> String? {
        lines.first { $0.lowercased().contains(needle.lowercased()) }
    }

    /// 「标签 值」或「标签: 值」或标签在上一行、值在下一行(券商表格 OCR 常见)。
    /// 订单参数行:限价、止损价、触发价 —— 下单时自己设的数,**不是成交价**。
    static func isOrderParameter(_ ln: String) -> Bool {
        let l = ln.lowercased()
        return ["limit price", "stop price", "trigger price", "限价", "止损价", "触发价"]
            .contains { l.contains($0) }
    }

    private static func labeled(_ lines: [String], _ labels: [String]) -> ParsedField<Double>? {
        for (i, ln) in lines.enumerated() {
            let low = ln.lowercased()
            guard let lab = labels.first(where: { low.contains($0.lowercased()) }) else { continue }
            // ★ 崩溃修复(2026-09-01):原来在 `low` 上取 range,却拿去索引 `ln` ——
            //   **两个 String 的 index 不通用**,而 lowercased() 可能改变长度
            //   (例如 İ → i̇ 会变长),于是 upperBound 越过 ln.endIndex,
            //   构造区间时抛 "Range requires lowerBound <= upperBound"。
            //   真机日志里就是这一条。改成直接在 ln 上做不区分大小写的查找。
            if let r = ln.range(of: lab, options: [.caseInsensitive, .diacriticInsensitive]) {
                let tail = String(ln[r.upperBound...])
                if let v = firstNumber(tail) { return ParsedField(v, 0.9, ln) }
            }
            // 再看下一行(表格布局)
            if i + 1 < lines.count, let v = firstNumber(lines[i + 1]),
               numbersOnly(lines[i + 1]) {
                return ParsedField(v, 0.75, "\(ln) → \(lines[i + 1])")
            }
        }
        return nil
    }

    private static func numbersOnly(_ s: String) -> Bool {
        s.range(of: #"^[\s$¥,.\d%+-]+$"#, options: .regularExpression) != nil
    }

    private static func firstNumber(_ s: String) -> Double? {
        guard let m = s.range(of: #"-?\d[\d,]*\.?\d*"#, options: .regularExpression) else { return nil }
        return Double(s[m].replacingOccurrences(of: ",", with: ""))
    }

    /// 标题行里的行权价:「QQQ 250806 717 CALL」「QQQ $717 Call 8/6」。
    private static func strikeFromHeader(_ lines: [String]) -> ParsedField<Double>? {
        for ln in lines.prefix(4) {
            let low = ln.lowercased()
            guard low.contains("call") || low.contains("put") || low.contains("看涨") || low.contains("看跌")
            else { continue }
            // 取该行里**最像行权价**的数:3 位以上、不是日期(不含 / 或 -)
            let nums = matches(ln, #"\$?\d{2,6}(\.\d+)?"#)
                .map { $0.replacingOccurrences(of: "$", with: "") }
                .compactMap(Double.init)
                .filter { $0 >= 1 }
            // 日期形态的 6 位数(250806)要排除:紧跟在标的后且 >= 200000
            if let k = nums.filter({ $0 < 100_000 }).max() {
                return ParsedField(k, 0.7, ln)
            }
        }
        return nil
    }

    private static func expiryFromHeader(_ lines: [String]) -> ParsedField<DateComponents>? {
        for ln in lines.prefix(5) {
            // YYMMDD 紧凑写法(moomoo/富途:QQQ 250806 717 CALL)
            if let m = ln.range(of: #"\b(2\d)(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\b"#,
                                options: .regularExpression) {
                let s = String(ln[m])
                var c = DateComponents()
                c.year = 2000 + Int(s.prefix(2))!; c.month = Int(s.dropFirst(2).prefix(2))
                c.day = Int(s.suffix(2))
                return ParsedField(c, 0.85, ln)
            }
            // 06AUG26 / 6 Aug 26
            if let d = monthNameDate(ln) { return ParsedField(d, 0.8, ln) }
        }
        return nil
    }

    private static let monthMap = ["jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                                   "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12]

    /// 月份名形式的日期。**只取紧挨月份名的数字** ——
    /// 「BOT 2 QQQ 06AUG26 …」里整行第一个数是张数 2,取它会把日期读成 2 号。
    private static func monthNameDate(_ s: String) -> DateComponents? {
        let low = s.lowercased()
        for (name, mm) in monthMap {
            guard let r = low.range(of: name) else { continue }
            // 月份名之前紧邻的数字(06AUG26 / 6 Aug)
            let before = String(low[low.startIndex..<r.lowerBound])
            let after  = String(low[r.upperBound...])
            let dayBefore = matches(before, #"(\d{1,2})\s*$"#).compactMap(Int.init).first
            let numsAfter = matches(after, #"\d{1,4}"#).compactMap(Int.init)
            // Aug 6, 2026 这种日在后
            let dayAfter = dayBefore == nil ? numsAfter.first(where: { $0 >= 1 && $0 <= 31 }) : nil
            guard let day = dayBefore ?? dayAfter else { continue }
            var c = DateComponents(); c.month = mm; c.day = day
            let yearPool = numsAfter.filter { $0 != day }
            if let y = yearPool.first(where: { $0 >= 2000 && $0 <= 2100 }) { c.year = y }
            else if let y2 = yearPool.first(where: { $0 >= 24 && $0 <= 99 }) { c.year = 2000 + y2 }
            return c
        }
        return nil
    }

    /// 成交时间。
    ///
    /// ★ 两个真图才暴露的问题:
    /// ① **状态栏的手机时间会被当成成交时间**(实测把 10:56 当成了成交的 10:13)。
    ///    ⇒ 优先取**带成交关键词的那一行**(Filled / 成交时间 / Executed …),
    ///      整页只有一个时间时才退回它。
    /// ② **日期与时间常常不在同一行**(Wealthsimple:`Filled  September 1, 2026` / `10:13 am`)。
    ///    ⇒ 选定时间行之后,向前后各看两行找日期。
    private static let fillWords = ["filled", "fill", "executed", "execution", "成交时间",
                                    "成交", "trade time", "time", "submitted"]

    private static func timestamp(_ lines: [String]) -> ParsedField<DateComponents>? {
        // ★★ 结尾原来是 `\b`,而真图 OCR 出来的是 **"3:43pm"(没有空格)** ——
        //   "3" 和 "p" 都是词字符,中间**没有词边界**,于是整个时间匹配不上,
        //   最后取到了状态栏的 15:44。改成「后面不是数字或冒号」即可。
        let timeRE = #"\b([01]?\d|2[0-3]):([0-5]\d)(:[0-5]\d)?(?![\d:])"#
        // 候选:(行号, 是否靠近成交关键词)
        var cands: [(Int, Bool)] = []
        for (i, ln) in lines.enumerated() where ln.range(of: timeRE, options: .regularExpression) != nil {
            let near = (max(0, i - 1)...min(lines.count - 1, i)).contains {
                let l = lines[$0].lowercased()
                return fillWords.contains { l.contains($0) }
            }
            cands.append((i, near))
        }
        guard !cands.isEmpty else { return nil }
        // 靠近成交关键词的优先;都不靠近就取最后一个(状态栏总在最上面)
        let idx = cands.first(where: { $0.1 })?.0 ?? cands.last!.0
        let ln = lines[idx]

        let hm = ln.range(of: timeRE, options: .regularExpression)!
        let t = String(ln[hm]).split(separator: ":").compactMap { Int($0) }
        var c = DateComponents()
        c.hour = t.first; c.minute = t.count > 1 ? t[1] : 0
        let low = ln.lowercased()
        if low.contains("pm"), let h = c.hour, h < 12 { c.hour = h + 12 }
        if low.contains("am"), c.hour == 12 { c.hour = 0 }

        // 日期:先看本行,再看前后两行
        for j in [idx, idx - 1, idx + 1, idx - 2, idx + 2] where j >= 0 && j < lines.count {
            let s = lines[j]
            if let dm = s.range(of: #"\b(20\d\d)[/-](\d{1,2})[/-](\d{1,2})\b"#,
                                options: .regularExpression) {
                let p = String(s[dm]).split(whereSeparator: { "/-".contains($0) }).compactMap { Int($0) }
                if p.count >= 3 { c.year = p[0]; c.month = p[1]; c.day = p[2]; break }
            }
            if let d = monthNameDate(s), d.day != nil {
                c.year = d.year ?? c.year; c.month = d.month; c.day = d.day; break
            }
        }
        return ParsedField(c, c.day != nil ? 0.9 : 0.6, ln)
    }

    private static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
