import XCTest
@testable import ReviewEngine

/// 纪律冻结检查。规范 §2.3:**绝对不要事后重算这一块** ——
/// 值钱的不是「显示规则」,是「系统警告过、用户仍然做了」这条**行为**记录。
final class TradingRulesTests: XCTestCase {

    private func t(_ hh: Int, _ mm: Int, day: Int = 1) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day
        c.hour = hh; c.minute = mm; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private func trade(open: (Int, Int), close: (Int, Int), win: Bool, day: Int = 1) -> Trade {
        let leg = Leg(kind: .equity)
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t(open.0, open.1, day: day), side: .buy,
                 quantity: 10, price: 100),
            Fill(legID: leg.id, time: t(close.0, close.1, day: day), side: .sell,
                 quantity: 10, price: win ? 110 : 90),
        ])
    }

    func testConfidenceBelowThresholdWarns() {
        let v = RuleEngine.check(.init(minConfidence: 4),
                                 .init(confidence: 3, closedToday: [], allClosed: []))
        XCTAssertEqual(v.first { $0.id == "confidence" }?.level, .warn)
        // ★ 断言**拼完的句子**里有数字 —— 现在存的是「格式 key + 冻结的数字」,
        //   只看 key 会永远看不到数字,那等于把这条规矩测没了。
        XCTAssertTrue(v.first { $0.id == "confidence" }?.detailText.contains("3") ?? false,
                      "要写出具体数字,不能只给个红叉")
    }

    func testConsecutiveLossesBlocks() {
        let today = [trade(open: (9,40), close: (9,50), win: false),
                     trade(open: (10,0), close: (10,10), win: false),
                     trade(open: (10,20), close: (10,30), win: false)]
        let v = RuleEngine.check(.init(maxConsecutiveLosses: 3),
                                 .init(confidence: 5, now: t(10,40),
                                       closedToday: today, allClosed: today))
        XCTAssertEqual(v.first { $0.id == "consecutive_losses" }?.level, .blocked)
    }

    /// 中间赢过一笔就不算「连亏」——连续性要真的连续。
    func testWinBreaksTheLosingStreak() {
        let today = [trade(open: (9,40), close: (9,50), win: false),
                     trade(open: (10,0), close: (10,10), win: true),
                     trade(open: (10,20), close: (10,30), win: false)]
        XCTAssertEqual(RuleEngine.consecutiveLosses(today), 1)
    }

    /// ★ 没填净值时,「日亏 X%」必须显示「判不了」,**不许显示通过**。
    func testUnknownWhenEquityMissing() {
        let v = RuleEngine.check(.init(equity: nil),
                                 .init(confidence: 5, closedToday: [], allClosed: []))
        let d = v.first { $0.id == "daily_loss" }
        XCTAssertEqual(d?.level, .unknown, "判不了就说判不了 —— 显示通过比不显示更糟")
        XCTAssertTrue(d?.detailText.contains("净值") ?? false)
    }

    func testDailyLossLimitBlocks() {
        let today = [trade(open: (9,40), close: (9,50), win: false)]   // −$100
        let v = RuleEngine.check(.init(dailyLossLimitPct: 1, equity: 5000),
                                 .init(confidence: 5, now: t(10,0),
                                       closedToday: today, allClosed: today))
        XCTAssertEqual(v.first { $0.id == "daily_loss" }?.level, .blocked, "−100 已超 5000 的 1%")
    }

    func testCooldownAfterLoss() {
        let today = [trade(open: (10,0), close: (10,10), win: false)]
        let hot = RuleEngine.check(.init(coolDownMinutesAfterLoss: 15),
                                   .init(confidence: 5, now: t(10,15),
                                         closedToday: today, allClosed: today))
        XCTAssertEqual(hot.first { $0.id == "cooldown" }?.level, .blocked, "才过 5 分钟")
        let cool = RuleEngine.check(.init(coolDownMinutesAfterLoss: 15),
                                    .init(confidence: 5, now: t(10,40),
                                          closedToday: today, allClosed: today))
        XCTAssertEqual(cool.first { $0.id == "cooldown" }?.level, .pass)
    }

    /// ★★ 整个功能的重点:警告过 + 仍然做了,要能被统计出来。
    func testProceededAnywayIsCounted() {
        let warnSnap = RuleSnapshot(verdicts: [
            .init(id: "confidence", label: "信心度", level: .warn, detail: "3")
        ], proceededAnyway: true)
        let cleanSnap = RuleSnapshot(verdicts: [
            .init(id: "confidence", label: "信心度", level: .pass, detail: "5")
        ], proceededAnyway: false)

        func withSnap(_ s: RuleSnapshot, win: Bool, day: Int) -> Trade {
            var t = trade(open: (10,0), close: (11,0), win: win, day: day)
            t.psychology = Psychology(states: ["有把握"], confidence: 3,
                                      recordedAt: self.t(9,50, day: day),
                                      beforeOutcome: true, ruleSnapshot: s)
            return t
        }
        let s = PortfolioStats.compute([
            withSnap(warnSnap, win: false, day: 1),
            withSnap(warnSnap, win: false, day: 2),
            withSnap(cleanSnap, win: true, day: 3),
        ])
        XCTAssertEqual(s.warnedCount, 2, "两笔被警告过")
        XCTAssertEqual(s.proceededAnywayCount, 2, "★ 两笔都照做了")
        XCTAssertEqual(s.proceededAnywayPnL, -200, accuracy: 1e-6,
                       "那两笔合计亏 $200 —— 这才是这条记录的价值")
    }

    /// 规则从没拦过你 = 从没被检验过,要进 never_happened。
    func testNeverTriggeredRulesSurface() {
        let clean = RuleSnapshot(verdicts: [
            .init(id: "confidence", label: "信心度", level: .pass, detail: "5")
        ], proceededAnyway: false)
        var t = trade(open: (10,0), close: (11,0), win: true)
        t.psychology = Psychology(states: ["有把握"], confidence: 5,
                                  recordedAt: self.t(9,50), beforeOutcome: true,
                                  ruleSnapshot: clean)
        let s = PortfolioStats.compute([t])
        XCTAssertTrue(s.neverHappened.contains { $0.contains("规则从未拦过你") },
                      "实际:\(s.neverHappened)")
    }
}

/// 示例数据。竞品 1 星差评:「删了它还会自己回来」。
final class SampleTradeTests: XCTestCase {

    private func mk(sample: Bool) -> Trade {
        let leg = Leg(kind: .equity)
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy,  quantity: 10, price: 100),
            Fill(legID: leg.id, time: Date(), side: .sell, quantity: 10, price: 110),
        ], finalUnderlying: 105, isSample: sample)
    }

    /// ★ 示例交易**不进任何统计** —— 否则用户的历史分析会被我编的数污染。
    func testSampleExcludedFromStats() {
        let s = PortfolioStats.compute([mk(sample: true), mk(sample: false)])
        XCTAssertEqual(s.nTotal, 1)
        XCTAssertEqual(s.nClosed, 1, "示例不算数")
        XCTAssertEqual(s.totalPnL, 100, accuracy: 1e-6, "只算真实那一笔")
    }

    /// 全是示例时,统计应该是空的,而不是显示一堆假数据。
    func testOnlySamplesMeansEmptyStats() {
        let s = PortfolioStats.compute([mk(sample: true)])
        XCTAssertEqual(s.nClosed, 0)
        XCTAssertNil(s.vsBestAlternative)
    }

    /// 存取往返要保住这个标记 —— 丢了它示例就混进统计了。
    func testSampleFlagSurvivesRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TradeStore(url: dir.appendingPathComponent("trades.json"))
        try store.save([mk(sample: true), mk(sample: false)])
        let back = try store.load()
        XCTAssertEqual(back.filter(\.isSample).count, 1)
        XCTAssertEqual(back.filter { !$0.isSample }.count, 1)
    }
}
