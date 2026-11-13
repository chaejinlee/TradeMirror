import XCTest
@testable import ReviewEngine

/// 记完一笔之后弹哪一页。
///
/// ★★ 这一组测试是**用户 2026-09-03 那个 bug 的回归测试**:
///   「完整的一笔完成的订单 ≥2 张截图放入软件之后不能填写交易入场以及出场原因」。
///   旧行为是「已平仓 ⇒ 直接进复盘页」,而复盘页没有填原因的地方 ⇒
///   那两个字段永远只能靠改单去补。下面第一条测试就是照着这个写的:
///   <b>改回旧逻辑,它会红。</b>
final class ImportFlowTests: XCTestCase {

    private var t0: Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 2
        c.hour = 10; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func trade(closed: Bool, entry: String?, exit: String?) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 708,
                                    expiry: t0.addingTimeInterval(21600)))
        var fills = [Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: 1.00)]
        if closed {
            fills.append(Fill(legID: leg.id, time: t0.addingTimeInterval(600),
                              side: .sell, quantity: 1, price: 1.50))
        }
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills)
        t.entryReason = entry; t.exitReason = exit
        return t
    }

    // ── 已平仓 ──────────────────────────────────────────────────────

    /// ★ 回归:整笔一次进来(≥2 张截图拼成的),**必须先问原因**。
    func testClosedTradeWithNoReasonsAsksFirst() {
        let t = trade(closed: true, entry: nil, exit: nil)
        XCTAssertTrue(t.isClosed)
        XCTAssertEqual(ImportFlow.next(after: t), .askReasons,
                       "整笔进来就直接跳复盘页 ⇒ 原因永远填不上(用户 09-03 报的那条)")
    }

    /// 只缺出场原因也要问 —— 少一个,历史页就有一块汇总是空的。
    func testClosedTradeMissingOnlyExitReasonStillAsks() {
        let t = trade(closed: true, entry: "结构位", exit: nil)
        XCTAssertEqual(ImportFlow.next(after: t), .askReasons)
    }

    func testClosedTradeMissingOnlyEntryReasonStillAsks() {
        let t = trade(closed: true, entry: nil, exit: "触及目标")
        XCTAssertEqual(ImportFlow.next(after: t), .askReasons)
    }

    /// 两个都有了才直接进复盘。
    func testClosedTradeWithBothReasonsGoesStraightToReview() {
        let t = trade(closed: true, entry: "结构位", exit: "触及目标")
        XCTAssertEqual(ImportFlow.next(after: t), .review)
    }

    /// 问完(或跳过)之后,已平仓的接着进复盘页。
    func testAfterReasonsClosedGoesToReview() {
        XCTAssertEqual(ImportFlow.afterReasons(trade(closed: true, entry: nil, exit: nil)),
                       .review)
    }

    // ── 未平仓 ──────────────────────────────────────────────────────

    /// 未平仓只看开单原因 —— 那一刻还没有「为什么走」这件事。
    func testOpenTradeAsksOnlyForEntryReason() {
        XCTAssertEqual(ImportFlow.next(after: trade(closed: false, entry: nil, exit: nil)),
                       .askReasons)
        XCTAssertEqual(ImportFlow.next(after: trade(closed: false, entry: "结构位", exit: nil)),
                       .none, "未平仓不该因为缺出场原因被反复追问")
    }

    /// 未平仓填完计划就停在列表 —— 反事实还算不出来,进复盘页只会看到一堆「算不了」。
    func testAfterReasonsOpenStaysPut() {
        XCTAssertEqual(ImportFlow.afterReasons(trade(closed: false, entry: "结构位", exit: nil)),
                       .none)
    }
}
