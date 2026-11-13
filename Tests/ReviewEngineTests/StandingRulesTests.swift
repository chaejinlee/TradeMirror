import XCTest
@testable import ReviewEngine

/// 常驻熔断器 + 对账提醒。
///
/// ★★ 都来自 2026-09-22 的复盘:
///   ① `RuleEngine.check` 全项目只有一个调用点(开仓前那一屏),
///     而 23 笔里只有 6 笔填过心理状态 ⇒ <b>熔断器四次里最多被问到一次</b>。
///   ② 对账记录数是 <b>0</b> ⇒ 我给这个 App 写的每一条「对上了」的测试都是循环的。
final class StandingRulesTests: XCTestCase {

    private var cal: Calendar { PeriodStats.cal }
    private func at(_ m: Int, _ d: Int, _ h: Int = 10, _ mi: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
        c.hour = h; c.minute = mi; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// 一笔已平仓、盈亏 = `pnl`、出场时刻 = `exit`。
    private func trade(_ pnl: Double, exit: Date, open: Date? = nil) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: exit))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: open ?? exit.addingTimeInterval(-600),
                 side: .buy, quantity: 1, price: 1),
            Fill(legID: leg.id, time: exit, side: .sell, quantity: 1,
                 price: (100 + pnl) / 100)])
    }

    func testFixtureIsRight() {
        XCTAssertEqual(trade(-300, exit: at(9, 22)).displayablePnL ?? 0, -300, accuracy: 1e-6)
    }

    // ── 两个入口共用同一份规则 ──────────────────────────────────────

    /// ★★ 开仓前那一屏 = 信心度 + 常驻那几条。<b>规则只能有一处定义。</b>
    func testOpenTimeCheckIsStandingPlusConfidence() {
        let r = TradingRules()
        let today = [trade(-300, exit: at(9, 22, 9, 30))]
        let full = RuleEngine.check(r, .init(confidence: 1, now: at(9, 22, 10),
                                             closedToday: today, allClosed: today))
        let stand = RuleEngine.standing(r, .init(now: at(9, 22, 10), closedToday: today))
        XCTAssertEqual(full.count, stand.count + 1, "只多一条信心度")
        XCTAssertEqual(full.first?.id, "confidence")
        XCTAssertEqual(Array(full.dropFirst()).map(\.id), stand.map(\.id),
                       "★ 其余每一条都必须和常驻那份**逐条一致**")
        for (a, b) in zip(full.dropFirst(), stand) {
            XCTAssertEqual(a.level, b.level, "\(a.id) 两个入口判出了不同的结果")
        }
    }

    /// 常驻那份里**不许**出现信心度 —— 主页判不了「这一单」。
    func testStandingHasNoPerTradeRule() {
        let v = RuleEngine.standing(TradingRules(), .init(closedToday: []))
        XCTAssertFalse(v.contains { $0.id == "confidence" })
        XCTAssertTrue(v.contains { $0.id == "consecutive_losses" })
        XCTAssertTrue(v.contains { $0.id == "daily_loss" })
        XCTAssertTrue(v.contains { $0.id == "cooldown" })
    }

    // ── 主页横幅什么时候出现 ────────────────────────────────────────

    /// ★ 全过就**不出声**。常驻的绿色提示等于没有提示。
    func testQuietWhenNothingIsWrong() {
        let s = RuleEngine.status(TradingRules(equity: 10_000),
                                  .init(now: at(9, 22, 14), closedToday: []))
        XCTAssertFalse(s.shouldShow)
        XCTAssertEqual(s.worst, .pass)
    }

    /// ★★ 重演 2026-09-04:当天亏到 −$893。净值填了就该拦。
    func testTheDayHeLost893WouldHaveBeenBlocked() {
        let r = TradingRules(equity: 10_000)        // 默认日亏上限是净值的百分之几
        let s = RuleEngine.status(r, .init(now: at(9, 4, 14),
                                           closedToday: [trade(-893, exit: at(9, 4, 13, 31))]))
        XCTAssertTrue(s.shouldShow, "−$893 / $10,000 应该触发日亏上限")
        XCTAssertEqual(s.worst, .blocked)
        XCTAssertTrue(s.hits.contains { $0.id == "daily_loss" })
    }

    /// ★★ <b>没填净值就判不了 —— 而且必须说「判不了」,不许显示「通过」。</b>
    ///   这正是它当时没能说话的原因之一。
    func testWithoutEquityTheDailyLossRuleSaysItCannotJudge() {
        let v = RuleEngine.standing(TradingRules(),          // equity = nil
                                    .init(now: at(9, 4, 14),
                                          closedToday: [trade(-893, exit: at(9, 4, 13))]))
        let dl = v.first { $0.id == "daily_loss" }
        XCTAssertEqual(dl?.level, .unknown, "判不了就说判不了")
        XCTAssertNotEqual(dl?.level, .pass, "★ 绝不许因为没数据就显示「通过」")
    }

    /// 连亏触发。
    func testConsecutiveLossesShowUp() {
        let r = TradingRules(maxConsecutiveLosses: 2)
        let s = RuleEngine.status(r, .init(now: at(9, 22, 14), closedToday: [
            trade(-100, exit: at(9, 22, 10)), trade(-100, exit: at(9, 22, 11))]))
        XCTAssertTrue(s.shouldShow)
        XCTAssertTrue(s.hits.contains { $0.id == "consecutive_losses" })
    }

    /// 规则整体关掉时一条都不判,横幅也不挂。
    func testDisabledRulesAreSilent() {
        var r = TradingRules(); r.enabled = false
        XCTAssertTrue(RuleEngine.standing(r, .init(closedToday: [])).isEmpty)
        XCTAssertFalse(RuleEngine.status(r, .init(closedToday: [])).shouldShow)
    }
}

/// 对账提醒 —— **唯一能打破循环验证的东西**。
final class ReconciliationPromptTests: XCTestCase {

    private func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        c.hour = 12; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    private func trade(openedAt: Date) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: openedAt))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: openedAt, side: .buy, quantity: 1, price: 1),
            Fill(legID: leg.id, time: openedAt.addingTimeInterval(600),
                 side: .sell, quantity: 1, price: 1.2)])
    }

    /// ★ 当月**不问** —— 月结单还没出。
    func testDoesNotAskAboutTheCurrentMonth() {
        let ts = [trade(openedAt: at(2026, 9, 4))]
        XCTAssertNil(ReconciliationPrompt.next(trades: ts, records: [], now: at(2026, 9, 22)))
    }

    /// 月份过完了就该问,而且要把「App 里记了几笔」写出来。
    func testAsksAboutTheFinishedMonth() {
        let ts = (1...9).map { trade(openedAt: at(2026, 8, $0)) }
        let a = ReconciliationPrompt.next(trades: ts, records: [], now: at(2026, 9, 22))
        XCTAssertEqual(a?.monthKey, "2026-08")
        XCTAssertEqual(a?.recorded, 9, "★ 直接告诉他 App 里是几笔,省得自己数")
    }

    /// 填过的不再问。
    func testAnsweredMonthsAreNotAskedAgain() {
        let ts = (1...9).map { trade(openedAt: at(2026, 8, $0)) }
        let r = [Reconciliation(monthKey: "2026-08", brokerTradeCount: 11)]
        XCTAssertNil(ReconciliationPrompt.next(trades: ts, records: r, now: at(2026, 9, 22)))
    }

    /// ★★ 一次只问**最早的那个** —— 一口气弹三个月,没人会填。
    func testAsksOneMonthAtATimeOldestFirst() {
        let ts = [trade(openedAt: at(2026, 6, 3)), trade(openedAt: at(2026, 7, 3)),
                  trade(openedAt: at(2026, 8, 3))]
        let a = ReconciliationPrompt.next(trades: ts, records: [], now: at(2026, 9, 22))
        XCTAssertEqual(a?.monthKey, "2026-06")
        XCTAssertEqual(a?.monthsOverdue, 3, "拖了 3 个月,数字要能看出来")
    }

    /// 那个月一笔都没做 ⇒ 没什么可对的,不问。
    func testMonthsWithNoTradesAreSkipped() {
        let ts = [trade(openedAt: at(2026, 8, 3))]
        let a = ReconciliationPrompt.next(trades: ts, records: [], now: at(2026, 9, 22))
        XCTAssertEqual(a?.monthKey, "2026-08", "7 月没交易,跳过它")
    }

    /// ★ 太久远的不问 —— <b>翻不到的月结单,问了只会让人学会忽略提醒。</b>
    func testAncientMonthsAreNotAsked() {
        let ts = [trade(openedAt: at(2025, 1, 3))]
        XCTAssertNil(ReconciliationPrompt.next(trades: ts, records: [],
                                               now: at(2026, 9, 22), lookback: 6))
    }

    /// 示例数据不参与。
    func testSampleTradesDoNotTriggerAPrompt() {
        var t = trade(openedAt: at(2026, 8, 3)); t.isSample = true
        XCTAssertNil(ReconciliationPrompt.next(trades: [t], records: [], now: at(2026, 9, 22)))
    }

    func testNoTradesNoPrompt() {
        XCTAssertNil(ReconciliationPrompt.next(trades: [], records: [], now: at(2026, 9, 22)))
    }
}
