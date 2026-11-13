import XCTest
@testable import ReviewEngine

/// **开发工具,不是测试。** 没设 `SEED_DEST` 时直接跳过,永远不进 CI。
///
/// 往模拟器写一份**用户的真实交易**(2026-09-18 导出的 23 笔 + 09-22/23 的 BEX 来回
/// + 一笔还没平的 BEX 波段仓),用 App 自己的编码器写 —— 手拼 JSON 被拒过三次。
///
/// ★ 为什么留成常驻:这一路改界面要反复拍前后对比,这个种子之前已经临时重写了五遍。
///   用法:`tools/seed_sim.sh`
final class DevSeedTests: XCTestCase {
    func testWriteSeed() throws {
        guard let dest = ProcessInfo.processInfo.environment["SEED_DEST"] else {
            throw XCTSkip("开发工具:没设 SEED_DEST 就不跑")
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
            c.hour = h; c.minute = mi; c.timeZone = TradingDay.exchangeTimeZone
            return cal.date(from: c)!
        }
        // (月, 日, 行权价, 是 Call?, [(买量, 价)], (卖量, 价), 出场原因, 入场时刻, 出场时刻)
        typealias Row = (Int, Int, Double, Bool, [(Double, Double)], (Double, Double), String?,
                         (Int, Int), (Int, Int))
        let rows: [Row] = [
            (8,3,692,true,[(1,1.47),(1,1.93),(1,3.08)],(3,3.03),"提前手动平",(9,53),(10,29)),
            (8,5,720,false,[(10,0.505)],(10,0.73),"触及目标",(15,30),(15,48)),
            (8,6,714,true,[(1,2.64)],(1,3.21),"触及目标",(9,44),(9,54)),
            (8,6,717,true,[(2,2.17),(1,1.57)],(3,2.51),"触及目标",(10,30),(11,2)),
            (8,28,723,true,[(4,1.21)],(4,1.87),"触及目标",(10,47),(11,1)),
            (8,28,717.5,true,[(1,1.20)],(1,0.26),nil,(12,39),(14,40)),
            (8,31,715,true,[(5,0.74)],(5,0.83),"触及目标",(11,37),(11,54)),
            (8,31,714,false,[(4,0.76)],(4,0.93),nil,(11,55),(11,59)),
            (8,31,715,true,[(8,0.4038)],(8,0.73),"触及目标",(13,36),(13,43)),
            (9,1,708,true,[(3,1.34)],(3,2.41),nil,(10,13),(10,35)),
            (9,2,707,true,[(3,1.14)],(3,2.41),nil,(9,57),(10,19)),
            (9,2,709,true,[(8,0.63),(3,0.76)],(11,0.79),nil,(11,0),(11,20)),
            (9,2,709,true,[(3,1.01),(2,0.59)],(5,0.47),nil,(11,52),(12,30)),
            (9,3,712,true,[(2,1.39)],(2,1.87),nil,(11,0),(11,30)),
            (9,3,713,true,[(3,1.04)],(3,2.70),"触及目标",(11,5),(11,40)),
            (9,3,719,true,[(30,0.55),(10,0.37)],(40,0.59),nil,(11,10),(14,2)),
            (9,3,718,true,[(10,0.26)],(10,0.12),"破位离场",(15,29),(15,43)),
            (9,4,721,true,[(2,1.45),(1,1.76)],(3,1.93),nil,(9,53),(9,59)),
            (9,4,721,true,[(3,1.22),(1,0.65),(2,0.32),(10,0.257),(5,0.13),(9,0.17),(3,0.0733)],
                (33,0.03),"破位离场",(10,14),(13,31)),
            (9,8,721,true,[(5,0.914),(2,0.595),(2,0.38),(2,0.30),(2,0.28),(10,0.12)],
                (23,0.04),"破位离场",(11,42),(15,19)),
            (9,15,705,false,[(3,1.01),(20,1.10),(6,1.84)],(29,1.67),"触及目标",(10,38),(10,52)),
            (9,15,705,false,[(5,0.78)],(5,0.55),"触及止损",(12,48),(12,52)),
            (9,15,706,true,[(6,0.79),(5,0.83),(8,0.37)],(19,0.29),nil,(12,53),(13,29)),
        ]
        var out: [Trade] = []
        for x in rows {
            let expiry = at(x.0, x.1, 16, 0)
            let leg = Leg(kind: .option(right: x.3 ? .call : .put, strike: x.2, expiry: expiry))
            let t0 = at(x.0, x.1, x.7.0, x.7.1), t1 = at(x.0, x.1, x.8.0, x.8.1)
            let n = Double(max(1, x.4.count - 1))
            var fills = x.4.enumerated().map { j, b in
                Fill(legID: leg.id, time: t0.addingTimeInterval(t1.timeIntervalSince(t0) * 0.8 * Double(j) / n),
                     side: .buy, quantity: b.0, price: b.1) }
            fills.append(Fill(legID: leg.id, time: t1, side: .sell, quantity: x.5.0, price: x.5.1))
            var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills)
            t.exitReason = x.6
            out.append(t)
        }
        // BEX:8 月的波段仓(还没平)+ 09-22/23 那一笔来回
        let swing = Leg(kind: .equity)
        out.append(Trade(symbol: "BEX", strategy: .single, legs: [swing], fills: [
            Fill(legID: swing.id, time: at(8, 5, 15, 48), side: .buy, quantity: 467, price: 24.97)]))
        let rt = Leg(kind: .equity)
        var bexRT = Trade(symbol: "BEX", strategy: .single, legs: [rt], fills: [
            Fill(legID: rt.id, time: at(9, 22, 15, 20), side: .buy, quantity: 130, price: 36.91),
            Fill(legID: rt.id, time: at(9, 23, 10, 18), side: .sell, quantity: 130, price: 37.2307)])
        bexRT.exitReason = "提前手动平"
        out.append(bexRT)

        try TradeStore(url: URL(fileURLWithPath: dest))
            .save(out, plans: [], closes: .init(), rules: TradingRules(equity: 20_000))
        let s = Distribution.summary(out)
        print("   ✅ 种子:\(out.count) 笔 · 已平 \(s.n) · 合计 $\(Int(s.total))")
    }
}
