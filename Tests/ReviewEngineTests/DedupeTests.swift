import XCTest
@testable import ReviewEngine

/// 去重。★ 起因:2026-09-02 用户「重新导入了,文件全部重复了」——
/// 我的导入脚本每跑一次换一批 UUID,而去重只看 id。
final class DedupeTests: XCTestCase {

    private func trade(day: Int = 6, price: Double = 1.34, strike: Double = 708) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = day
        c.hour = 10; c.minute = 30; c.timeZone = TradingDay.exchangeTimeZone
        let t0 = Calendar(identifier: .gregorian).date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: strike,
                                    expiry: t0.addingTimeInterval(20_000)))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 3, price: price),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .sell,
                 quantity: 3, price: 2.41),
        ])
    }

    /// 把一笔「重新发一遍 id」—— 模拟脚本重跑
    private func reissue(_ t: Trade) -> Trade {
        var x = t
        x.id = UUID()
        for i in x.legs.indices { x.legs[i].id = UUID() }
        for i in x.fills.indices { x.fills[i].id = UUID(); x.fills[i].legID = x.legs[0].id }
        return x
    }

    func testSameContentSameFingerprint() {
        let a = trade()
        XCTAssertEqual(a.fingerprint, reissue(a).fingerprint,
                       "★ 换了 id 不该变成另一笔")
    }

    func testDifferentPriceDifferentFingerprint() {
        XCTAssertNotEqual(trade(price: 1.34).fingerprint, trade(price: 1.35).fingerprint)
    }

    func testDifferentStrikeDifferentFingerprint() {
        XCTAssertNotEqual(trade(strike: 708).fingerprint, trade(strike: 715).fingerprint)
    }

    func testDifferentDayDifferentFingerprint() {
        XCTAssertNotEqual(trade(day: 5).fingerprint, trade(day: 6).fingerprint)
    }

    func testAnnotationsDoNotChangeIdentity() {
        // ★ 备注/心理/原因/收盘价是**后来补的注解** —— 补了不该变成另一笔,
        //   否则「补过数据的那份」和「原始那份」会被当成两笔,永远清不掉。
        var a = trade()
        let before = a.fingerprint
        a.rawNoteAtEntry = "旗形突破"
        a.psychology = Psychology(states: ["有把握"], confidence: 4,
                                  recordedAt: Date(), beforeOutcome: true)
        a.entryReason = "结构位"
        a.plannedStop = 1.0
        a.finalUnderlying = 707.64
        a.legs[0].userClosePrice = 0.25
        XCTAssertEqual(a.fingerprint, before)
    }

    func testFindsTheDuplicateGroup() {
        let a = trade()
        let dups = Deduper.find(in: [a, reissue(a), reissue(a)])
        XCTAssertEqual(dups.count, 1)
        XCTAssertEqual(dups[0].drop.count, 2)
    }

    func testKeepsTheRichestCopy() {
        // ★★ 用户可能已经在其中一份上补过收盘价/心理/原因 —— 删错了就得白填一遍
        var rich = trade()
        rich.finalUnderlying = 707.64
        rich.entryReason = "结构位"
        rich.psychology = Psychology(states: ["有把握"], confidence: 4,
                                     recordedAt: Date(), beforeOutcome: true)
        let bare = reissue(trade())
        for order in [[rich, bare], [bare, rich]] {      // 顺序不该影响结果
            let d = Deduper.find(in: order)
            XCTAssertEqual(d.count, 1)
            XCTAssertEqual(d[0].keep.id, rich.id, "必须留填得最多的那份")
        }
    }

    func testNoDuplicatesMeansEmpty() {
        XCTAssertTrue(Deduper.find(in: [trade(day: 5), trade(day: 6)]).isEmpty)
    }

    func testSampleIsNeverTreatedAsADuplicate() {
        var s = trade(); s.isSample = true
        var real = trade(); real.id = UUID()
        XCTAssertTrue(Deduper.find(in: [s, real]).isEmpty,
                      "示例本来就该是独立的一条,不许把用户真实那笔当成它的副本删掉")
    }

    func testIdsToDropNeverIncludesAKeeper() {
        let a = trade()
        let all = [a, reissue(a), reissue(a)]
        let drop = Deduper.idsToDrop(in: all)
        XCTAssertEqual(drop.count, 2)
        let kept = all.filter { !drop.contains($0.id) }
        XCTAssertEqual(kept.count, 1, "★ 每组必须**至少留一笔**,不许全删")
    }

    func testSecondsLevelJitterIsStillTheSameTrade() {
        // 券商截图的秒位常常对不上,但那不该算两笔
        var a = trade()
        var b = reissue(a)
        b.fills[0].time = a.fills[0].time.addingTimeInterval(31)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        a.fills[0].time = a.fills[0].time.addingTimeInterval(-1)   // 触碰边界不崩
        XCTAssertNoThrow(a.fingerprint)
    }
}
