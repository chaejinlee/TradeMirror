import XCTest
@testable import ReviewEngine

/// 黄金测试 —— 全部数字来自 `review_payload_example.json`(2026-08-06 QQQ 717C 0DTE 真实成交)。
///
/// 这些不是造出来的用例。规范是从 5 笔真实交易反推的,payload 是用本地 1min 存档填的。
/// **引擎算不出这些数,就是引擎错了。**
final class GoldenTrade0806Tests: XCTestCase {

    // 2026-08-06 各时刻
    static func t(_ hhmm: String) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 6
        c.hour = Int(hhmm.prefix(2)); c.minute = Int(hhmm.suffix(2))
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// 08-06 那笔:10:30 买 2 张 @2.17,10:47 浮亏 27.6% 时加 1 张 @1.57,11:02 全平 @2.51
    static func makeTrade() -> Trade {
        Trade(symbol: "QQQ",
              instrument: .option(right: .call, strike: 717, expiry: t("1600")),
              isLong: true,
              fills: [
                Fill(time: t("1030"), side: .buy,  quantity: 2, price: 2.17, underlying: 717.24),
                Fill(time: t("1047"), side: .buy,  quantity: 1, price: 1.57, underlying: 716.45),
                Fill(time: t("1102"), side: .sell, quantity: 3, price: 2.51, underlying: 718.04),
              ],
              exitReason: "触及目标",
              rawNoteAtEntry: "价格看涨旗走出,并且在今日重要成交量分部位出现明显支撑。")
    }

    // MARK: - 基本量

    func testBasicsMatchPayload() {
        let tr = Self.makeTrade()
        XCTAssertEqual(tr.costBasis,     591, accuracy: 0.01, "建仓成本 = 2.17*2*100 + 1.57*1*100")
        XCTAssertEqual(tr.proceeds,      753, accuracy: 0.01, "出场市值 = 2.51*3*100")
        XCTAssertEqual(tr.realizedPnL,   162, accuracy: 0.01, "规范 pnl_usd = 162")
        XCTAssertEqual(tr.averageEntry, 1.97, accuracy: 0.005, "规范 avg_entry = 1.97")
        XCTAssertEqual(tr.averageExit,  2.51, accuracy: 0.001)
        XCTAssertTrue(tr.isClosed)
    }

    /// ★ 规范坑 #6:只存均价的话,这个行为在数据里会彻底消失。
    func testDetectsAddWhileUnderwater() {
        let adds = Self.makeTrade().addsWhileUnderwater
        XCTAssertEqual(adds.count, 1, "10:47 那笔是浮亏加仓")
        XCTAssertEqual(adds[0].unrealizedPct, -27.6, accuracy: 0.1, "规范 unrealized_pct_at_fill = -27.6")
    }

    // MARK: - 定价口径(这条错了,所有 0DTE 重定价全错)

    /// 规范记录 IV 12.0%。实测只有**交易时间**口径能复现;日历口径是 28.5%,差 2.4 倍。
    func testImpliedVolOnlyMatchesUnderTradingTimeBasis() {
        let tr = Self.makeTrade()
        let ivTrading = CounterfactualEngine.impliedVolAtExit(
            trade: tr, hoursToExpiryAtExit: 4.97, basis: .tradingTime)
        let ivCalendar = CounterfactualEngine.impliedVolAtExit(
            trade: tr, hoursToExpiryAtExit: 4.97, basis: .calendar)
        XCTAssertNotNil(ivTrading); XCTAssertNotNil(ivCalendar)
        XCTAssertEqual(ivTrading!,  0.1234, accuracy: 0.003, "规范记录 12.0%")
        XCTAssertEqual(ivCalendar!, 0.2854, accuracy: 0.003, "日历口径 —— 记录在此,防止有人改默认值")
    }

    /// BS 退化行为:T<=0 时必须等于内在价值,不能返回时间价值。
    func testPricingDegradesToIntrinsicAtExpiry() {
        XCTAssertEqual(BlackScholes.price(right: .call, spot: 719.05, strike: 717,
                                          years: 0, sigma: 0.12), 2.05, accuracy: 1e-9)
        XCTAssertEqual(BlackScholes.price(right: .call, spot: 715.56, strike: 717,
                                          years: 0, sigma: 0.12), 0, accuracy: 1e-9)
    }

    /// 市价低于内在价值时必须返回 nil,不许给猜测值。
    func testImpliedVolReturnsNilWhenUnsolvable() {
        XCTAssertNil(BlackScholes.impliedVolatility(right: .call, spot: 719.05, strike: 717,
                                                    years: 0.0005, price: 1.00))
    }

    // MARK: - 反事实

    /// 若不加仓:$68。规范 no_add_on.first_tranche_only = 68。
    /// ★ 差额为 −94 ⇒ 判定必须是「你做得更好」—— 加仓在结果上是对的。
    ///   这正是规范说的**危险的正强化**:一个高风险行为拿到了正反馈。
    func testNoAddOnMatchesPayload() {
        let cf = CounterfactualEngine.noAddOn(trade: Self.makeTrade())
        XCTAssertNotNil(cf)
        XCTAssertEqual(cf!.alternativePnL, 68,  accuracy: 0.01, "规范 first_tranche_only = 68")
        XCTAssertEqual(cf!.actualPnL,     162,  accuracy: 0.01)
        XCTAssertEqual(cf!.delta,         -94,  accuracy: 0.01, "规范 add_contributed = 94")
        XCTAssertEqual(cf!.verdict, .youWereBetter)
    }

    /// ★★ 规范 §3.1 最重要的一条:0DTE 持有到收盘 = 归零。
    /// 只算「卖早了」的话,用户会学到「应该拿久一点」这个错误结论。
    func testHoldToCloseGoesToZero() {
        let tr = Self.makeTrade()
        let cf = CounterfactualEngine.holdToClose(trade: tr, finalUnderlying: 715.56)
        XCTAssertEqual(cf.alternativePnL, -591, accuracy: 0.01, "3 张全部归零,亏掉全部成本")
        XCTAssertEqual(cf.delta,          -753, accuracy: 0.01, "规范 hold_to_eod.delta = -753")
        XCTAssertEqual(cf.verdict, .youWereBetter)
    }

    /// 出场 vs 峰值。规范 peak_value = 942(用四舍五入的 IV 12.0% 算的)。
    /// 引擎用**精确反解**的 IV,得 944 —— 差 0.2%,来源是 IV 的舍入,不是算法分歧。
    func testExitVsPeakWithinRoundingOfPayload() {
        let tr = Self.makeTrade()
        let iv = CounterfactualEngine.impliedVolAtExit(trade: tr, hoursToExpiryAtExit: 4.97)!
        let cf = CounterfactualEngine.exitVsPeak(trade: tr, peakUnderlying: 719.05,
                                                 hoursToExpiryAtPeak: 4.97 + 2.0/60.0, sigma: iv)
        let peakValue = cf.alternativePnL + tr.costBasis
        XCTAssertEqual(peakValue, 942, accuracy: 5, "规范 peak_value = 942;精确 IV 下为 944")
        XCTAssertEqual(cf.delta, 189, accuracy: 5, "规范 left_on_table = 189")
        XCTAssertEqual(cf.verdict, .alternativeWasBetter)
    }

    /// 汇总:v1 只有 fills + 两个用户填的数,能出三条反事实,
    /// 且必须**主动报出还缺什么**(规则化分批出场要分钟级路径,v1 拿不到)。
    func testAllReportsWhatIsMissing() {
        let r = CounterfactualEngine.all(trade: Self.makeTrade(),
                                         peakUnderlying: 719.05, hoursToExpiryAtPeak: 4.97 + 2.0/60.0,
                                         finalUnderlying: 715.56, hoursToExpiryAtExit: 4.97)
        XCTAssertEqual(r.results.count, 3)
        XCTAssertEqual(Set(r.results.map(\.id)), ["no_add_on", "exit_vs_peak", "hold_to_close"])
        XCTAssertTrue(r.missing.contains(.intradayPath), "必须诚实报出这一项算不了")
        XCTAssertNotNil(r.impliedVol)
        // ★ C7 的机器可验版本:三条里两条判「你做得更好」,一条判「替代更好」——
        //    引擎不会一边倒地生成后悔。
        XCTAssertEqual(r.results.filter { $0.verdict == .youWereBetter }.count, 2)
        XCTAssertEqual(r.results.filter { $0.verdict == .alternativeWasBetter }.count, 1)
    }
}

/// 第二批:来自 2026-08-30 抓取的 177 条竞品真实差评所暴露的问题。
/// 每个测试上面都注明它对应哪一条用户抱怨 —— **测试是需求的载体,不是形式**。
final class CompetitorFailureModeTests: XCTestCase {

    /// 对应差评:「Can't even enter multiple entries to same stock」
    ///          「you can't include add-on buys. You have to do a separate transaction」
    /// 竞品做不到同一标的多次入场;而规范的核心设计就是 fill 级 schema。
    func testSupportsMultipleEntriesOnSameSymbol() {
        let tr = GoldenTrade0806Tests.makeTrade()
        XCTAssertEqual(tr.buys.count, 2, "两次买入必须是同一笔交易的两个 fill,不是两笔交易")
        XCTAssertEqual(tr.totalBought, 3)
        XCTAssertEqual(tr.averageEntry, 1.97, accuracy: 0.005)
    }

    /// 对应差评:「pnl's on Saturdays and Sundays」「shift my trades from Monday to Sunday」
    /// 交易日必须按交易所时区判定,不跟设备时区走。
    func testTradingDayUsesExchangeTimeZoneNotDevice() {
        let tr = GoldenTrade0806Tests.makeTrade()
        XCTAssertEqual(tr.tradingDayKey, "2026-08-06")
        XCTAssertFalse(tr.hasWeekendFill, "工作日的交易不允许落到周末")
        // 纽约 10:30 = UTC 14:30。若用 UTC 归日期仍是同一天;
        // 真正会出事的是收盘后的成交 —— 纽约 20:00 在 UTC 已是次日。
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 6
        c.hour = 20; c.minute = 0; c.timeZone = TimeZone(identifier: "America/New_York")
        let evening = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(TradingDay.key(of: evening), "2026-08-06",
                       "纽约当晚 20:00 在 UTC 已是 8-7;按交易所时区必须仍归 8-6")
    }

    /// 「平一半 + 剩余持有到强平」:3 张 → 平 2 留 1,留下的那张归零。
    /// 结果 502 vs 实际 753 ⇒ 判「你做得更好」。
    /// ★ 这是第三条判用户做对的反事实 —— 0DTE 里「分批出场让利润奔跑」当天是错的。
    func testScaleOutAndHoldWouldHaveBeenWorse() {
        let tr = GoldenTrade0806Tests.makeTrade()
        let cf = CounterfactualEngine.scaleOutAndHold(trade: tr, finalUnderlying: 715.56)
        XCTAssertNotNil(cf)
        XCTAssertEqual(cf!.alternativePnL, 2 * 2.51 * 100 - 591, accuracy: 0.01)
        XCTAssertEqual(cf!.verdict, .youWereBetter)
        XCTAssertTrue(cf!.note!.contains("简化版"), "不许冒充完整规则")
    }

    /// MAE 只能从成交点观测,是**下界**不是真值。把下界说成真值等于编数据。
    func testObservedMAEIsLowerBoundFromFills() {
        let mae = CounterfactualEngine.observedMAE(trade: GoldenTrade0806Tests.makeTrade())
        XCTAssertNotNil(mae)
        XCTAssertEqual(mae!.pct, -27.6, accuracy: 0.1)
    }

    /// MFE 捕获率 = 你的出场市值 / 峰值市值。行业标准说法,ASO 与用户理解都更好。
    func testMFECaptureRate() {
        let tr = GoldenTrade0806Tests.makeTrade()
        let iv = CounterfactualEngine.impliedVolAtExit(trade: tr, hoursToExpiryAtExit: 4.97)!
        let cf = CounterfactualEngine.exitVsPeak(trade: tr, peakUnderlying: 719.05,
                                                 hoursToExpiryAtPeak: 4.97 + 2.0/60.0, sigma: iv)
        let rate = CounterfactualEngine.mfeCaptureRate(exitVsPeak: cf, costBasis: tr.costBasis)!
        XCTAssertEqual(rate, 753.0 / 944.0, accuracy: 0.01, "吃到峰值的约 80%")
    }
}

/// 对应差评「all my trades got deleted」「Update reset my results」——
/// 数据丢失占竞品差评 29%,是这个品类最大的失败模式。
final class StoreDataLossTests: XCTestCase {

    private func tempStore() -> TradeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TradeStore(url: dir.appendingPathComponent("trades.json"))
    }

    func testRoundTripPreservesFillLevelDetail() throws {
        let s = tempStore(), tr = GoldenTrade0806Tests.makeTrade()
        try s.save([tr])
        let back = try s.load()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].fills.count, 3, "fill 级明细不许在存取中被压扁")
        XCTAssertEqual(back[0].realizedPnL, 162, accuracy: 0.01)
        XCTAssertEqual(back[0].addsWhileUnderwater.count, 1, "浮亏加仓必须能从读回的数据里重算出来")
        XCTAssertEqual(back[0].rawNoteAtEntry, tr.rawNoteAtEntry, "用户原话必须原样保留")
    }

    func testFreshInstallReturnsEmptyNotError() throws {
        XCTAssertEqual(try tempStore().load().count, 0)
    }

    /// ★ 最关键的一条:文件坏了**绝不能静默返回空**——
    /// 那正是「打开 App 发现数据没了」的实现方式。必须抛错,且坏文件已留档。
    func testCorruptFileThrowsAndKeepsBackupInsteadOfSilentlyReturningEmpty() throws {
        let s = tempStore()
        try s.save([GoldenTrade0806Tests.makeTrade()])
        try "{ 这不是合法 JSON".data(using: .utf8)!.write(to: s.url)
        do {
            _ = try s.load()
            XCTFail("坏文件必须抛错,不许返回空数组")
        } catch StoreError.unreadable(let backup) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup),
                          "坏文件必须被留档,用户的数据不能凭空消失")
        }
    }

    /// 未来版本的文件不许被当前版本当成空的读进来再存回去(那会直接抹掉新字段)。
    func testFutureSchemaIsRejectedNotSilentlyDowngraded() throws {
        let s = tempStore()
        try #"{"schemaVersion":999,"trades":[]}"#.data(using: .utf8)!.write(to: s.url)
        XCTAssertThrowsError(try s.load())
    }

    /// 覆盖写之后旧数据不残留、新数据完整。
    func testOverwriteIsAtomicAndComplete() throws {
        let s = tempStore()
        try s.save([GoldenTrade0806Tests.makeTrade()])
        try s.save([])
        XCTAssertEqual(try s.load().count, 0)
        try s.save([GoldenTrade0806Tests.makeTrade(), GoldenTrade0806Tests.makeTrade()])
        XCTAssertEqual(try s.load().count, 2)
    }
}

/// 2026-08-31 实测中发现的真 bug:只录了买入的一笔,列表里显示成红色 −$434。
/// **未平仓的持仓成本不是亏损。** 这正是竞品 1 星差评里的
/// 「distorting P/L」「numbers don't add up」,而本 App 的定位就是「算得对」。
final class OpenPositionPnLTests: XCTestCase {

    private func openTrade() -> Trade {
        Trade(symbol: "QQQ",
              instrument: .option(right: .call, strike: 717, expiry: Date()),
              isLong: true,
              fills: [Fill(time: Date(), side: .buy, quantity: 2, price: 2.17, underlying: 717.24)])
    }

    func testOpenPositionReportsNoPnLInsteadOfNegativeCost() {
        let t = openTrade()
        XCTAssertFalse(t.isClosed)
        XCTAssertNil(t.displayablePnL, "未平仓不许给出一个看起来像亏损的数")
        XCTAssertEqual(t.openQuantity, 2)
        XCTAssertEqual(t.realizedPnL, -434, accuracy: 0.01,
                       "realizedPnL 本身仍是 回收−成本;它只是不该被直接展示")
    }

    func testClosedPositionStillReportsPnL() {
        XCTAssertEqual(GoldenTrade0806Tests.makeTrade().displayablePnL ?? .nan, 162, accuracy: 0.01)
    }

    /// 部分平仓:仍未平完,同样不许展示盈亏。
    func testPartiallyClosedIsStillOpen() {
        var t = openTrade()
        t.fills.append(Fill(time: Date(), side: .sell, quantity: 1, price: 2.51, underlying: 718.04))
        XCTAssertFalse(t.isClosed)
        XCTAssertNil(t.displayablePnL)
        XCTAssertEqual(t.openQuantity, 1)
    }
}
