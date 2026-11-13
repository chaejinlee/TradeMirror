import XCTest
@testable import ReviewEngine

/// 纪律手册 + 每笔的自检。
///
/// ★ 用户 2026-09-03 发来两页手写笔记:「整理好添加到复盘软件里,作为纪律手册。
///   并且完成每单就按照里面的问我遵守了哪些,没遵守哪些」。
///
/// ★★ 这一组测试守的是同一条底线:<b>没勾 ≠ 遵守了。</b>
///   把「没答」算成「做到了」,守纪率会永远好看 ——
///   而拿一个假数字让人安心,是这个 App 最不该做的事。
final class DisciplineTests: XCTestCase {

    private func at(_ h: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 3
        c.hour = h; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func closed(pnl: Double, check: DisciplineCheck? = nil) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: at(16)))
        // 买 1 张 @1.00,卖出价按想要的盈亏倒推
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: at(10), side: .buy, quantity: 1, price: 1.00),
            Fill(legID: leg.id, time: at(11), side: .sell, quantity: 1,
                 price: 1.00 + pnl / 100),
        ])
        t.discipline = check
        return t
    }

    // ── 三态 ────────────────────────────────────────────────────────

    /// ★★ 没勾的**不算遵守**。
    func testUnansweredIsNotCountedAsFollowed() {
        let a = UUID(), b = UUID(), c = UUID()
        let chk = DisciplineCheck(followed: [a], broken: [b])   // c 没勾
        XCTAssertEqual(chk.answered, 2, "只答了 2 条")
        XCTAssertFalse(chk.followed.contains(c))
        XCTAssertFalse(chk.broken.contains(c))
        XCTAssertEqual(chk.followRate ?? -1, 0.5, accuracy: 1e-9,
                       "分母是**答过的**,不是手册的总条数")
    }

    /// 一条都没答时不给守纪率 —— **不返回 0,也不返回 1**。
    func testNoAnswersGivesNoRate() {
        let chk = DisciplineCheck()
        XCTAssertTrue(chk.isEmpty)
        XCTAssertNil(chk.followRate)
    }

    // ── 什么时候该问 ────────────────────────────────────────────────

    func testOnlyClosedTradesAreAsked() {
        let book = DisciplineBook.seed
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: at(16)))
        let open = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: at(10), side: .buy, quantity: 1, price: 1.0),
        ])
        XCTAssertFalse(ImportFlow.needsDiscipline(open, book: book),
                       "还没走完的单,问「守没守规矩」问不出结论")
        XCTAssertTrue(ImportFlow.needsDiscipline(closed(pnl: 100), book: book))
    }

    /// 手册是空的就别问 —— 没有规矩可对照时,那只是一张空表。
    func testEmptyBookMeansNoQuestion() {
        XCTAssertFalse(ImportFlow.needsDiscipline(closed(pnl: 100), book: DisciplineBook()))
    }

    /// 答过了就不再问。
    func testAlreadyAnsweredIsNotAskedAgain() {
        let t = closed(pnl: 100, check: DisciplineCheck(followed: [UUID()]))
        XCTAssertFalse(ImportFlow.needsDiscipline(t, book: .seed))
    }

    /// 流程顺序:原因 → 纪律 → 复盘。
    func testFlowGoesReasonsThenDisciplineThenReview() {
        var t = closed(pnl: 100)
        XCTAssertEqual(ImportFlow.next(after: t, book: .seed), .askReasons)
        t.entryReason = "结构位"; t.exitReason = "触及目标"
        XCTAssertEqual(ImportFlow.next(after: t, book: .seed), .askDiscipline)
        t.discipline = DisciplineCheck(followed: [UUID()])
        XCTAssertEqual(ImportFlow.next(after: t, book: .seed), .review)
        XCTAssertEqual(ImportFlow.afterDiscipline(t), .review)
    }

    // ── 汇总 ────────────────────────────────────────────────────────

    func testTalliesCountBreaksAndAttachPnL() {
        let rule = DisciplineRule(text: "冲动性交易", kind: .avoid)
        let book = DisciplineBook(rules: [rule])
        let s = DisciplineEngine.compute([
            closed(pnl: -200, check: DisciplineCheck(broken: [rule.id])),
            closed(pnl: -100, check: DisciplineCheck(broken: [rule.id])),
            closed(pnl: 300, check: DisciplineCheck(followed: [rule.id])),
        ], book: book)

        XCTAssertEqual(s.checkedTrades, 3)
        let t = try? XCTUnwrap(s.tallies.first)
        XCTAssertEqual(t?.text, "冲动性交易")
        XCTAssertEqual(t?.broken, 2)
        XCTAssertEqual(t?.followed, 1)
        XCTAssertEqual(t?.brokenPnL ?? 0, -300, accuracy: 1e-6)
        XCTAssertEqual(t?.followedPnL ?? 0, 300, accuracy: 1e-6)
        XCTAssertEqual(t?.breakRate ?? 0, 2.0 / 3.0, accuracy: 1e-9)
    }

    /// ★★ 两边都有样本才给差额。只有一边就返回 nil ——
    ///   拿一个只有一边有样本的差额去下结论,是这个项目里最常见的那类假话。
    func testCostOfBreakingNeedsBothSides() {
        let r = DisciplineRule(text: "冲动性交易", kind: .avoid)
        let book = DisciplineBook(rules: [r])

        let onlyBroken = DisciplineEngine.compute(
            [closed(pnl: -200, check: DisciplineCheck(broken: [r.id]))], book: book)
        XCTAssertNil(onlyBroken.costOfBreaking, "只有破戒的样本,比不出差额")

        let both = DisciplineEngine.compute([
            closed(pnl: -200, check: DisciplineCheck(broken: [r.id])),
            closed(pnl: 300, check: DisciplineCheck(followed: [r.id])),
        ], book: book)
        XCTAssertEqual(both.costOfBreaking ?? 0, -500, accuracy: 1e-6,
                       "破戒平均 −200,守规矩平均 +300 ⇒ 少赚 500")
    }

    /// 没答过的交易**完全不参与**统计 —— 不能算成「守了」也不能算「破了」。
    func testUncheckedTradesAreExcludedEntirely() {
        let r = DisciplineRule(text: "冲动性交易", kind: .avoid)
        let s = DisciplineEngine.compute([
            closed(pnl: -999),                                    // 没答
            closed(pnl: 100, check: DisciplineCheck(followed: [r.id])),
        ], book: DisciplineBook(rules: [r]))
        XCTAssertEqual(s.checkedTrades, 1)
        XCTAssertEqual(s.avgPnLWhenClean ?? 0, 100, accuracy: 1e-6,
                       "那笔 −999 没答过,不许混进来")
        XCTAssertNil(s.avgPnLWhenBroken)
    }

    /// 示例交易不算 —— 它不是用户做的单。
    func testSampleTradesAreExcluded() {
        let r = DisciplineRule(text: "冲动性交易", kind: .avoid)
        var sample = closed(pnl: 500, check: DisciplineCheck(followed: [r.id]))
        sample.isSample = true
        let s = DisciplineEngine.compute([sample], book: DisciplineBook(rules: [r]))
        XCTAssertEqual(s.checkedTrades, 0)
    }

    // ── 手册本身 ────────────────────────────────────────────────────

    /// 种子清单来自用户的手写笔记,两类都得有内容。
    func testSeedHasBothKinds() {
        let b = DisciplineBook.seed
        XCTAssertFalse(b.active(.follow).isEmpty)
        XCTAssertFalse(b.active(.avoid).isEmpty)
        XCTAssertEqual(b.activeCount, b.rules.count, "种子里的默认全是启用的")
    }

    /// ★ 我认不准的那几条**必须带记号** —— 用户得一眼看出该核对哪几行。
    func testUncertainSeedLinesAreMarked() {
        let marked = DisciplineBook.seed.rules.filter {
            $0.text.hasPrefix(DisciplineBook.uncertainMark)
        }
        XCTAssertFalse(marked.isEmpty, "手写认不准的条目要标出来,不能装作都认对了")
    }

    /// 关掉的规则不进检查表,但**留在手册里** ——
    /// 直接删掉会连历史统计里那条的名字一起丢。
    func testDisabledRulesAreNotAskedButKept() {
        var b = DisciplineBook.seed
        b.rules[0].enabled = false
        XCTAssertFalse(b.active(b.rules[0].kind).contains { $0.id == b.rules[0].id })
        XCTAssertNotNil(b.rule(b.rules[0].id), "关掉 ≠ 删掉")
    }

    /// ★ 老存档没有这两个字段:必须照样读得出来(v8 栽过一次)。
    func testOldArchiveWithoutDisciplineStillDecodes() throws {
        let f = StoreFile(trades: [closed(pnl: 10)])
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(f)) as! [String: Any]
        json.removeValue(forKey: "discipline")
        let back = try JSONDecoder().decode(
            StoreFile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.discipline)
        XCTAssertEqual(back.trades.count, 1)
        XCTAssertNil(back.trades[0].discipline)
    }

    func testDisciplineSurvivesRoundTrip() throws {
        let r = UUID()
        let t = closed(pnl: 10, check: DisciplineCheck(followed: [r], broken: []))
        let back = try JSONDecoder().decode(Trade.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.discipline?.followed, [r])
    }
}
