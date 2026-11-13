import XCTest
@testable import ReviewEngine

/// 导入的**账**,以及「存不进去的那几张」。
///
/// ★★ 这一层针对的是 2026-09-04 的完整故障链,不是单个 bug:
///   OCR 丢价 → 绕过「不可用」的网 → 进草稿 → 保存时被 `continue` 扔掉
///   → 张数对不上 → 永远未平仓 → 不进任何统计。
///   <b>链上每一环都没报错,所以整条链是静默的。</b>
final class ImportTallyTests: XCTestCase {

    private func part(sym: String? = "QQQ", qty: Double? = 1,
                      px: Double? = 0.5, side: Side? = .buy) -> ParsedTrade {
        var p = ParsedTrade()
        if let s = sym  { p.symbol = ParsedField(s, 1, "") }
        if let q = qty  { p.quantity = ParsedField(q, 1, "") }
        if let x = px   { p.price = ParsedField(x, 1, "") }
        if let s = side { p.side = ParsedField(s, 1, "") }
        return p
    }

    // ── 账 ──────────────────────────────────────────────────────────

    /// ★★ 核心不变量:**张数必须对得上。**
    func testTallyBalances() {
        let t = ImportTally(selected: 8, unreadable: 0, ocrEmpty: 1, unusable: 2, accepted: 5)
        XCTAssertTrue(t.balances)
        XCTAssertEqual(t.dropped, 3)
    }

    /// 对不上就是对不上 —— 说明代码里还有一条没数到的静默路径。
    func testUnbalancedTallyIsReported() {
        let t = ImportTally(selected: 8, accepted: 5)     // 少的 3 张没人认领
        XCTAssertFalse(t.balances)
        XCTAssertTrue(t.needsAttention)
        let n = try! XCTUnwrap(t.note())
        XCTAssertTrue(n.contains("3 张不知去向"), n)
        XCTAssertTrue(n.contains("8"), "用户选了几张必须写在里面:\(n)")
    }

    /// ★ 全对的时候**不出声** —— 每次导入都弹一句「成功」等于没弹。
    func testCleanImportSaysNothing() {
        let t = ImportTally(selected: 5, accepted: 5)
        XCTAssertTrue(t.balances)
        XCTAssertFalse(t.needsAttention)
        XCTAssertNil(t.note())
    }

    /// ★★ 用户选了几张,这个数必须原样出现在提示里。
    ///   2026-09-04 页头写的是「来自 5 张截图」—— <b>「8」从来没到过那一屏。</b>
    func testSelectedCountSurvivesToTheMessage() {
        let n = try! XCTUnwrap(ImportTally(selected: 8, unusable: 3, accepted: 5).note())
        XCTAssertTrue(n.contains("8") && n.contains("5"), n)
        XCTAssertTrue(n.contains("3 张关键字段太少"), n)
    }

    // ── 能不能变成一笔成交 ──────────────────────────────────────────

    /// ★★ 这就是那三张的形状:**符号读对了,只丢了价。**
    ///   `isUsable` 说不行,但导入那一步判的是 `isUsable || symbol != nil` ——
    ///   于是它进来了。而它**变不成一笔成交**。
    func testSymbolReadButPriceLostIsNotAFill() {
        let p = part(px: nil)
        XCTAssertNotNil(p.symbol)
        XCTAssertFalse(p.isUsable)
        XCTAssertFalse(p.canBecomeFill, "缺价 ⇒ 变不成成交")
        XCTAssertEqual(p.fillBlockers(), ["成交价"])
    }

    func testBlockersAreListedInAFixedOrder() {
        XCTAssertEqual(part(qty: nil, px: nil, side: nil).fillBlockers(),
                       ["买卖方向", "张数", "成交价"])
        XCTAssertTrue(part().canBecomeFill)
        XCTAssertEqual(part().fillBlockers(), [])
    }

    /// 缺符号但字段齐 —— 能成交(符号从同组别的图上取)。
    func testMissingSymbolStillMakesAFill() {
        XCTAssertTrue(part(sym: nil).canBecomeFill)
    }

    // ── 整组能不能存 ────────────────────────────────────────────────

    func testDraftWithAnUnfillablePartIsIncomplete() {
        let d = BatchImporter.Draft(mergeInto: nil,
                                    parts: [part(), part(px: nil), part()], reason: "")
        XCTAssertFalse(d.isComplete)
        XCTAssertEqual(d.unfillableParts.count, 1)
    }

    func testDraftWithAllPartsFillableIsComplete() {
        XCTAssertTrue(BatchImporter.Draft(mergeInto: nil, parts: [part(), part()],
                                          reason: "").isComplete)
    }

    /// 手填一个价就能补齐 —— 死路变成能走的路。
    func testFillingInThePriceCompletesTheDraft() {
        var d = BatchImporter.Draft(mergeInto: nil, parts: [part(), part(px: nil)], reason: "")
        XCTAssertFalse(d.isComplete)
        d.fillInPrice(0.65, atPartIndex: 1)
        XCTAssertTrue(d.isComplete)
        XCTAssertEqual(d.parts[1].price?.value ?? 0, 0.65, accuracy: 1e-9)
        XCTAssertEqual(d.parts[1].price?.confidence ?? 0, 1.0, accuracy: 1e-9,
                       "手填的是用户亲口说的,置信度就是 1")
    }

    /// 0 和负数不算填 —— 空输入框不该把草稿变成「完整」。
    func testZeroPriceDoesNotCount() {
        var d = BatchImporter.Draft(mergeInto: nil, parts: [part(px: nil)], reason: "")
        d.fillInPrice(0, atPartIndex: 0)
        XCTAssertFalse(d.isComplete)
        d.fillInPrice(-1, atPartIndex: 0)
        XCTAssertFalse(d.isComplete)
        d.fillInPrice(99, atPartIndex: 999)          // 越界不许崩
        XCTAssertFalse(d.isComplete)
    }

    // ── ★★ 后果:重演 2026-09-04 那一天 ─────────────────────────────

    /// <b>这条测试是这次复盘的全部意义。</b>
    ///
    /// 真实数据:7 笔买入共 33 张、1 笔卖出 33 张,已平仓、亏 $892.99。
    /// 丢掉 3 笔没读出价的买入之后:买 27 卖 33 ⇒ 净 −6 ⇒ **永远未平仓**
    /// ⇒ `displayablePnL` 是 nil ⇒ 不进胜率、不进热力图、不进任何统计。
    ///
    /// ★ 于是历史页那两句话有了机械解释,而不是巧合:
    ///   「N/N 全是盈利单」和「逆势加仓 —— 0 次」——
    ///   <b>唯一那笔逆势加仓,正是被这条链路挡在统计之外的。</b>
    func testDroppingFillsTurnsAClosedLossIntoAnInvisibleOpenPosition() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 4
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let close = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 721, expiry: close))

        let readable = [(3.0, 1.22), (10.0, 0.257), (5.0, 0.13), (9.0, 0.17)]
        let lost     = [(1.0, 0.65), (2.0, 0.32), (3.0, 0.0733)]
        func trade(_ buys: [(Double, Double)]) -> Trade {
            var f = buys.map { Fill(legID: leg.id, time: close.addingTimeInterval(-7200),
                                    side: .buy, quantity: $0.0, price: $0.1) }
            f.append(Fill(legID: leg.id, time: close, side: .sell, quantity: 33, price: 0.03))
            return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: f)
        }

        // 全都在 ⇒ 平仓、亏 $892.99、而且是一笔**逆势加仓**
        let whole = trade(readable + lost)
        XCTAssertTrue(whole.isClosed)
        XCTAssertEqual(whole.displayablePnL ?? 0, -892.99, accuracy: 0.01)
        XCTAssertFalse(whole.addsWhileUnderwater.isEmpty,
                       "一路往下加了 6 次 —— 这正是历史页说「0 次」的那个模式")

        // 丢了 3 笔 ⇒ 买 27 卖 33 ⇒ 净 −6 ⇒ 永远不平 ⇒ 没有盈亏可显示
        let partial = trade(readable)
        XCTAssertFalse(partial.isClosed, "少存一笔成交,这笔就再也平不了")
        XCTAssertEqual(partial.openQuantity, 6, accuracy: 1e-9, "凭空多出 6 张反向持仓")
        XCTAssertNil(partial.displayablePnL,
                     "★ 未平仓不给盈亏 ⇒ 这笔亏损从统计里彻底消失,而且不报错")
    }
}

/// 备份**到底还活着没有**。
///
/// ★★ 2026-09-05 复盘查出来的:`_ = backupIfNeeded(...)` —— 返回值直接丢。
///   备份失败唯一的痕迹是「上次备份」那个日期不往前走,
///   而那一页是你**已经起疑**才会去看的。
final class BackupHealthTests: XCTestCase {

    private func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
        c.hour = h; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// 没选文件夹 = 没开这个功能,**不是故障** —— 别拿橙色吓人。
    func testNotConfiguredIsNotAnAlarm() {
        let h = BackupHealth.of(isConfigured: false, lastBackup: nil, lastError: "随便什么")
        XCTAssertEqual(h, .off)
        XCTAssertFalse(h.isAlarming)
        XCTAssertNil(h.message())
    }

    /// ★★ 失败必须说话 —— 这就是这次要补的洞。
    func testFailureSpeaksUpAndCarriesTheSystemsOwnWords() {
        let h = BackupHealth.of(isConfigured: true, lastBackup: at(9, 5),
                                lastError: "You don't have permission (NSCocoaErrorDomain 513)",
                                now: at(9, 5))
        XCTAssertTrue(h.isAlarming)
        let m = try! XCTUnwrap(h.message())
        XCTAssertTrue(m.contains("513"), "系统原话要带上,否则查不出是权限还是没同步:\(m)")
    }

    /// ★ 失败优先于「昨天成功过」—— 哪怕昨天好好的,今天失败了也要说。
    func testTodaysFailureOutranksYesterdaysSuccess() {
        let h = BackupHealth.of(isConfigured: true, lastBackup: at(9, 4),
                                lastError: "写不进去", now: at(9, 5))
        guard case .failing = h else { return XCTFail("应该是 failing,实际 \(h)") }
    }

    func testFreshBackupIsQuiet() {
        for d in [5, 4, 3] {          // 今天 / 昨天 / 前天
            let h = BackupHealth.of(isConfigured: true, lastBackup: at(9, d),
                                    lastError: nil, now: at(9, 5))
            XCTAssertEqual(h, .ok, "9/\(d) 备的,9/5 不该报警")
            XCTAssertFalse(h.isAlarming)
        }
    }

    /// ★★ 好几天没成过 —— 没有报错,但它已经死了。
    ///   文件夹被搬走、iCloud 掉线都是这个样子:<b>安静地不工作。</b>
    func testSilentlyDeadBackupIsCaught() {
        let h = BackupHealth.of(isConfigured: true, lastBackup: at(9, 1),
                                lastError: nil, now: at(9, 5))
        XCTAssertEqual(h, .stale(days: 4))
        XCTAssertTrue(h.isAlarming)
        XCTAssertTrue(try! XCTUnwrap(h.message()).contains("4"))
    }

    /// 选了文件夹却一次都没备过 —— 也算不正常。
    func testConfiguredButNeverBackedUpIsStale() {
        let h = BackupHealth.of(isConfigured: true, lastBackup: nil, lastError: nil,
                                now: at(9, 5))
        XCTAssertTrue(h.isAlarming)
    }

    /// ★ 算的是**日历日**,不是 24 小时。昨天 23:50 → 今天 00:10 是 1 天。
    func testDaysAreCalendarDaysNotElapsedHours() {
        let h = BackupHealth.of(isConfigured: true, lastBackup: at(9, 1, 23),
                                lastError: nil, now: at(9, 4, 0), staleAfterDays: 3)
        XCTAssertEqual(h, .stale(days: 3), "隔了 3 个日历日,虽然还不到 3×24 小时")
    }
}

/// 「每张图恰好记一次」—— 做成**结构上成立**,而不是靠我记得。
///
/// ★★ 这次的病根就是「靠记得」的正确性:视图里三处 `guard … else { continue }`,
///   每一处都在把一张图变没,而没有一处留下痕迹。
extension ImportTallyTests {

    private func usable() -> ParsedTrade {
        var p = ParsedTrade()
        p.symbol = ParsedField("QQQ", 1, ""); p.quantity = ParsedField(1, 1, "")
        p.price = ParsedField(0.5, 1, "");    p.side = ParsedField(.buy, 1, "")
        return p
    }
    /// 2026-09-04 那三张的形状:符号读到了,价丢了。
    private func priceless() -> ParsedTrade {
        var p = usable(); p.price = nil; return p
    }

    func testOutcomeCoversEveryCase() {
        XCTAssertEqual(ImportTally.outcome(imageLoaded: false, lines: [], parsed: nil), .unreadable)
        XCTAssertEqual(ImportTally.outcome(imageLoaded: true, lines: [], parsed: nil), .ocrEmpty)
        XCTAssertEqual(ImportTally.outcome(imageLoaded: true, lines: ["噪声"],
                                           parsed: ParsedTrade()), .unusable)
        XCTAssertEqual(ImportTally.outcome(imageLoaded: true, lines: ["QQQ"],
                                           parsed: usable()), .accepted)
    }

    /// ★★ 只丢了价的那种**要收进来** —— 在这里扔掉,用户就没机会手填补齐。
    ///   门槛故意比 `isUsable` 低,但确认页会拦住它、要求补上。
    func testPricelessScreenshotIsAcceptedSoItCanBeFixedByHand() {
        let p = priceless()
        XCTAssertFalse(p.isUsable)
        XCTAssertEqual(ImportTally.outcome(imageLoaded: true, lines: ["QQQ"], parsed: p),
                       .accepted, "收进来 —— 但确认页不许它就这么存下去")
        XCTAssertFalse(p.canBecomeFill, "…而它变不成一笔成交,所以保存会被挡住")
    }

    /// ★★ 核心:**每张图记一次,账就永远平。**
    func testRecordingEveryScreenshotKeepsTheBooksBalanced() {
        let outcomes: [ImportTally.Outcome] =
            [.accepted, .accepted, .unusable, .ocrEmpty, .unreadable, .accepted, .accepted, .accepted]
        var t = ImportTally(selected: outcomes.count)
        for o in outcomes { t.record(o) }
        XCTAssertTrue(t.balances, "\(t)")
        XCTAssertEqual(t.accepted, 5)
        XCTAssertEqual(t.dropped, 3)
    }

    /// 漏记一张,账立刻不平 —— 这就是要的效果。
    func testForgettingToRecordOneIsCaught() {
        var t = ImportTally(selected: 3)
        t.record(.accepted); t.record(.accepted)     // 第三张忘了记
        XCTAssertFalse(t.balances)
        XCTAssertTrue(try! XCTUnwrap(t.note()).contains("1 张不知去向"))
    }

    /// ★★ 重演 2026-09-04:8 张、3 张缺价 —— 现在 8 张全收下,3 张标红挡住保存。
    func testTheEightScreenshotsFromSeptember4() {
        var t = ImportTally(selected: 8)
        var parts: [ParsedTrade] = []
        for i in 0..<8 {
            let p = [1, 2, 6].contains(i) ? priceless() : usable()
            let o = ImportTally.outcome(imageLoaded: true, lines: ["QQQ"], parsed: p)
            t.record(o)
            if o == .accepted { parts.append(p) }
        }
        XCTAssertTrue(t.balances)
        XCTAssertEqual(t.accepted, 8, "★ 一张都不许丢 —— 丢了用户就没法手填")
        XCTAssertNil(t.note(), "8 张全收下 ⇒ 页头不用报警,报警的是下面那三行红的")

        let d = BatchImporter.Draft(mergeInto: nil, parts: parts, reason: "")
        XCTAssertFalse(d.isComplete, "★★ 3 张缺价 ⇒ 保存按钮必须是灰的")
        XCTAssertEqual(d.unfillableParts.count, 3)
    }
}

/// **自成一笔的来回,不许被吞进已有仓位。**
///
/// ★★ 2026-09-23 用户:「这两张放进去记录不进去」。
///   他导的是 BEX 买 130 股 + 隔天卖 130 股 —— 一笔完整的来回,
///   券商自己在卖出那张上印着 `+$41.69 return`。
///   而他库里还有一笔 8 月开的、467 股的 BEX 波段仓。
///   「同一标的就并」把这来回<b>吞进了那个老仓位</b>:
///   净量 467+130−130 = 467 没变、日期还是 8/5、还是「未平仓」、没有盈亏
///   ⇒ <b>屏幕上前后一模一样。数据进去了,他什么也看不到。</b>
final class SelfContainedRoundTripTests: XCTestCase {

    private func part(_ sym: String, _ side: Side, _ qty: Double, _ px: Double,
                      h: Int, m: Int) -> ParsedTrade {
        var p = ParsedTrade()
        p.symbol = ParsedField(sym, 1, "")
        p.side = ParsedField(side, 1, "")
        p.quantity = ParsedField(qty, 1, "")
        p.price = ParsedField(px, 1, "")
        var c = DateComponents(); c.hour = h; c.minute = m
        p.time = ParsedField(c, 1, "")
        return p
    }

    /// 库里那笔 8 月开的 467 股 BEX。
    private func openBEX() -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 5
        c.hour = 15; c.minute = 48; c.timeZone = TradingDay.exchangeTimeZone
        let t = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .equity)
        return Trade(symbol: "BEX", strategy: .single, legs: [leg],
                     fills: [Fill(legID: leg.id, time: t, side: .buy,
                                  quantity: 467, price: 24.97)])
    }

    func testTheFixtureIsWhatIThinkItIs() {
        let o = openBEX()
        XCTAssertFalse(o.isClosed)
        XCTAssertEqual(o.openQuantity, 467, accuracy: 1e-9)
    }

    /// ★★ 核心:买 130 + 卖 130 自己就平了 ⇒ **独立成笔**,不并进 467 那笔。
    func testAFlatRoundTripIsNotAbsorbedIntoAnOpenPosition() {
        let ds = BatchImporter.group(
            [part("BEX", .buy, 130, 36.91, h: 15, m: 20),
             part("BEX", .sell, 130, 37.2307, h: 10, m: 18)],
            existing: [openBEX()])
        XCTAssertEqual(ds.count, 1)
        XCTAssertNil(ds[0].mergeInto,
                     "★ 并进去等于把一笔可复盘的交易溶掉 —— 净量不变、日期不变、没有盈亏")
        XCTAssertEqual(ds[0].parts.count, 2)
    }

    /// ★ **没平的**那种照样并 —— 只加仓不卖,本来就该并进已有仓位。
    func testAnUnbalancedImportStillMerges() {
        let ds = BatchImporter.group([part("BEX", .buy, 130, 36.91, h: 15, m: 20)],
                                     existing: [openBEX()])
        XCTAssertEqual(ds.count, 1)
        XCTAssertNotNil(ds[0].mergeInto, "只买不卖 = 加仓,该并进去")
    }

    /// 买 130 + 卖 50:没平完 ⇒ 仍然并。
    func testPartialCloseStillMerges() {
        let ds = BatchImporter.group(
            [part("BEX", .buy, 130, 36.91, h: 15, m: 20),
             part("BEX", .sell, 50, 37.23, h: 10, m: 18)],
            existing: [openBEX()])
        XCTAssertNotNil(ds[0].mergeInto)
    }

    /// ★★ 独立成笔之后,盈亏必须**算得出来**,而且要和券商印的一致:
    ///   130 × (37.2307 − 36.91) = <b>+$41.69</b>。
    func testTheRoundTripYieldsTheBrokersOwnNumber() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 23
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "BEX", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0.addingTimeInterval(-86400),
                 side: .buy, quantity: 130, price: 36.91),
            Fill(legID: leg.id, time: t0, side: .sell, quantity: 130, price: 37.2307)])
        XCTAssertTrue(t.isClosed)
        XCTAssertEqual(t.displayablePnL ?? 0, 41.69, accuracy: 0.01,
                       "★ 券商自己在图上印着 +$41.69 return")
    }

    /// 期权同理:一批里自己配平的一对,不该并进同合约的未平仓。
    func testSameRuleForOptions() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 3
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let exp = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 718, expiry: exp))
        let open = Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                         fills: [Fill(legID: leg.id, time: exp.addingTimeInterval(-7200),
                                      side: .buy, quantity: 10, price: 0.26)])
        var b = part("QQQ", .buy, 5, 0.30, h: 10, m: 0)
        var s = part("QQQ", .sell, 5, 0.40, h: 11, m: 0)
        b.right = ParsedField(.call, 1, ""); b.strike = ParsedField(718, 1, "")
        s.right = ParsedField(.call, 1, ""); s.strike = ParsedField(718, 1, "")
        let ds = BatchImporter.group([b, s], existing: [open])
        XCTAssertEqual(ds.count, 1)
        XCTAssertNil(ds[0].mergeInto)
    }
}
