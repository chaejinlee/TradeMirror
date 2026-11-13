import XCTest
@testable import ReviewEngine

/// 持仓时间。
///
/// ★★ 这一层守两件事:① 每一笔「拿了多久」算得对、不知道就说不知道(估的时间、旧版 11:00 占位);
///   ② 结论只说站得住的 —— 用户真实数据里,赢单中位拿 8 分钟、亏单 20 分钟(p ≈ 0.6%),
///   而「拿得越久越亏」的整体趋势说不准(ρ = −0.21,p ≈ 0.13)。两个都要和外面独立算的对上。
final class HoldingTimeTests: XCTestCase {

    private func date(_ day: String, _ h: Int, _ m: Int, sec: Int = 0) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        c.hour = h; c.minute = m; c.second = sec; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }
    /// 一笔:open 时刻买 100 股,close 时刻卖,盈亏正好 = pnl。
    private func trade(_ od: String, _ oh: Int, _ om: Int, _ cd: String, _ ch: Int, _ cm: Int,
                       _ pnl: Double, openEstimated: Bool = false, closeEstimated: Bool = false,
                       closed: Bool = true) -> Trade {
        let leg = Leg(kind: .equity)
        var fills = [Fill(legID: leg.id, time: date(od, oh, om), side: .buy, quantity: 100, price: 10,
                          timeIsEstimated: openEstimated)]
        if closed {
            fills.append(Fill(legID: leg.id, time: date(cd, ch, cm), side: .sell, quantity: 100,
                              price: 10 + pnl / 100, timeIsEstimated: closeEstimated))
        }
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills)
    }

    // ── 每一笔拿了多久 ───────────────────────────────────────────

    func testHoldingIsFirstOpenToLastClose() {
        XCTAssertEqual(trade("2026-10-05", 10, 33, "2026-10-05", 10, 37, 50).holdingSeconds, 240)
        // 加仓、分批平:第一笔开仓 10:00 → 最后一笔平仓 10:25
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: date("2026-10-05", 10, 0), side: .buy, quantity: 1, price: 10),
            Fill(legID: leg.id, time: date("2026-10-05", 10, 5), side: .buy, quantity: 1, price: 9),
            Fill(legID: leg.id, time: date("2026-10-05", 10, 12), side: .sell, quantity: 1, price: 11),
            Fill(legID: leg.id, time: date("2026-10-05", 10, 25), side: .sell, quantity: 1, price: 12),
        ])
        XCTAssertEqual(t.holdingSeconds, 25 * 60)
    }

    /// 不知道就说不知道:时间是估的、旧版 11:00 占位、还没平 —— 一律 nil,不给一个假时长。
    func testUnknownHoldingIsNil() {
        XCTAssertNil(trade("2026-10-05", 10, 0, "2026-10-05", 10, 30, 50, openEstimated: true).holdingSeconds)
        XCTAssertNil(trade("2026-10-05", 10, 0, "2026-10-05", 10, 30, 50, closeEstimated: true).holdingSeconds)
        XCTAssertNil(trade("2026-09-03", 11, 0, "2026-09-03", 14, 2, 340).holdingSeconds,
                     "开仓 11:00 是旧版占位(9/3 那笔 719C)—— 拿了多久不知道")
        XCTAssertNil(trade("2026-10-05", 10, 0, "", 0, 0, 0, closed: false).holdingSeconds)
    }

    /// 段的边界左闭右开;隔夜单不看时长,单独一段。
    func testBuckets() {
        XCTAssertEqual(HoldingTime.bucket(seconds: 119, overnight: false), 0)
        XCTAssertEqual(HoldingTime.bucket(seconds: 120, overnight: false), 1)
        XCTAssertEqual(HoldingTime.bucket(seconds: 3599, overnight: false), 4)
        XCTAssertEqual(HoldingTime.bucket(seconds: 3600, overnight: false), 5)
        XCTAssertEqual(HoldingTime.bucket(seconds: 60, overnight: true), HoldingTime.overnightBucket)
        let bex = trade("2026-09-22", 15, 20, "2026-09-23", 10, 18, 41.69)
        XCTAssertTrue(bex.heldOvernight)
        XCTAssertEqual(bex.holdingSeconds, 1138 * 60)
        XCTAssertFalse(trade("2026-10-05", 9, 31, "2026-10-05", 15, 59, 1).heldOvernight)
    }

    func testFormat() {
        XCTAssertEqual(HoldingTime.format(25), "不到 1 分钟")
        XCTAssertEqual(HoldingTime.format(240), "4 分钟")
        XCTAssertEqual(HoldingTime.format(93 * 60), "1 小时 33 分")
        XCTAssertEqual(HoldingTime.format(2 * 3600), "2 小时")
        XCTAssertEqual(HoldingTime.format(1138 * 60), "18 小时 58 分")
        XCTAssertEqual(HoldingTime.format(3 * 86400), "3 天")
        XCTAssertEqual(HoldingTime.format(86400 + 5 * 3600), "1 天 5 小时")
    }

    // ── 用户的真实战绩(TimeOfDayTests 里那 57 笔,2026-10-03 从手机拷下来的)──

    private func realTrades() -> [Trade] {
        TimeOfDayTests.real.map { trade($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6) }
    }

    func testRealRecordBuckets() {
        let r = HoldingTime.report(realTrades())
        XCTAssertEqual(r.n, 53)
        XCTAssertEqual(r.excluded, 4, "4 笔开仓时间是旧版 11:00 占位")
        XCTAssertEqual(r.n + r.excluded, 57, "每一笔都有去处")
        XCTAssertEqual(r.buckets.map(\.trades.count), [2, 12, 20, 8, 6, 4, 1])
        let totals: [Double] = [-135, 1452.8, 3420.12, 1678, -1452, -2408.99, 41.69]
        for (b, want) in zip(r.buckets, totals) { XCTAssertEqual(b.summary.total, want, accuracy: 0.005) }
    }

    /// ★★ 站得住的那一条:亏单比赢单拿得久(外面独立算:Mann-Whitney 双侧 p = 0.0065)。
    func testLosersAreHeldLongerAndThatIsUnlikelyToBeChance() throws {
        let r = HoldingTime.report(realTrades())
        XCTAssertEqual(r.wins, 36); XCTAssertEqual(r.losses, 17)
        XCTAssertEqual(r.medianWinHold, 480)
        XCTAssertEqual(r.medianLossHold, 1200)
        let p = try XCTUnwrap(r.pHoldDiffers)
        XCTAssertEqual(p, 0.006, accuracy: 0.004)
        XCTAssertLessThan(p, 0.05)
    }

    /// 说不准的那一条:整体趋势(外面独立算:Spearman ρ = −0.2098,p = 0.13)。
    func testOverallTrendIsNotEstablished() throws {
        let r = HoldingTime.report(realTrades())
        XCTAssertEqual(try XCTUnwrap(r.rho), -0.2098, accuracy: 0.0005)
        let p = try XCTUnwrap(r.pRho)
        XCTAssertEqual(p, 0.13, accuracy: 0.04)
        XCTAssertGreaterThan(p, 0.05)
    }

    func testDeterministic() {
        let a = HoldingTime.report(realTrades()), b = HoldingTime.report(realTrades())
        XCTAssertEqual(a.pHoldDiffers, b.pHoldDiffers)
        XCTAssertEqual(a.pRho, b.pRho)
    }

    /// 笔数不够不给 p 值 —— 才几笔就说「显著」是在骗人。
    func testTooFewTradesGiveNoPValues() {
        let r = HoldingTime.report(Array(realTrades().prefix(12)))
        XCTAssertNil(r.pHoldDiffers); XCTAssertNil(r.pRho); XCTAssertNil(r.rho)
        XCTAssertNotNil(r.medianWinHold, "中位数照给 —— 那个算得出来")
    }

    /// 真有差别时要能认出来(检验本身不是摆设)。
    func testDetectsARealDifference() throws {
        var ts: [Trade] = []
        for i in 0..<15 { ts.append(trade("2026-10-05", 10, 0, "2026-10-05", 10, 2 + i % 3, 50)) }   // 赢:2–4 分钟
        for i in 0..<15 { ts.append(trade("2026-10-05", 11, 0 + 1, "2026-10-05", 12, 10 + i, -50)) } // 亏:1 小时多
        let r = HoldingTime.report(ts)
        XCTAssertLessThan(try XCTUnwrap(r.pHoldDiffers), 0.001)
    }
}
