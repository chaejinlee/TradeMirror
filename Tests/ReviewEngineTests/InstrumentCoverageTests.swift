import XCTest
@testable import ReviewEngine

/// 2026-08-31 扩品种后的测试。
/// 用户的原话:「只能记录期权,并且期权种类也只有 call 和 put 两种」。
/// 竞品差评里「期权价差 / forex / 期货不支持」占 21%,所以这不是锦上添花。
final class InstrumentCoverageTests: XCTestCase {

    static func t(_ hh: Int, _ mm: Int, day: Int = 6) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = day
        c.hour = hh; c.minute = mm; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - 做空

    /// ★ 修了一个旧实现的真 bug:做空时 `averageEntry` 只看买入,
    /// 会把**平仓价**显示成入场价。方向现在由**首笔成交**决定。
    func testShortStockEntryIsTheSellNotTheBuy() {
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "TSLA", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Self.t(10, 0), side: .sell, quantity: 100, price: 250, underlying: 250),
            Fill(legID: leg.id, time: Self.t(14, 0), side: .buy,  quantity: 100, price: 240, underlying: 240),
        ])
        XCTAssertEqual(t.openingSide(of: leg), .sell)
        XCTAssertEqual(t.averageEntry, 250, accuracy: 1e-9, "做空的入场是卖出那一笔")
        XCTAssertEqual(t.averageExit,  240, accuracy: 1e-9)
        XCTAssertEqual(t.realizedPnL, 1000, accuracy: 1e-9, "250→240 空 100 股 = +$1,000")
        XCTAssertEqual(t.netCredit, 25000, accuracy: 1e-9, "开仓是收钱")
        XCTAssertTrue(t.isClosed)
    }

    /// 做空的「逆势加仓」是价格涨上去之后继续加卖 —— 同一个行为,方向相反。
    func testShortAddWhileUnderwaterIsDetected() {
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "TSLA", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Self.t(10, 0), side: .sell, quantity: 100, price: 250, underlying: 250),
            Fill(legID: leg.id, time: Self.t(11, 0), side: .sell, quantity: 100, price: 262.5, underlying: 262.5),
        ])
        let adds = t.addsWhileUnderwater
        XCTAssertEqual(adds.count, 1, "涨了 5% 还加空,是逆势加仓")
        XCTAssertEqual(adds[0].unrealizedPct, -5.0, accuracy: 0.01)
    }

    // MARK: - 期货

    /// 点值写死在合约表里,不让用户填 —— 填错会让盈亏错一个数量级。
    func testFuturesUsePointValueNotOne() {
        let es = FuturesContract.find("ES")!
        XCTAssertEqual(es.pointValue, 50); XCTAssertEqual(es.tickValue, 12.5, accuracy: 1e-9)
        let mnq = FuturesContract.find("MNQ")!
        XCTAssertEqual(mnq.pointValue, 2)

        let leg = Leg(kind: es.legKind)
        let t = Trade(symbol: "ES", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Self.t(9, 35), side: .buy,  quantity: 2, price: 5000, underlying: 5000),
            Fill(legID: leg.id, time: Self.t(11, 0), side: .sell, quantity: 2, price: 5004, underlying: 5004),
        ])
        XCTAssertEqual(t.realizedPnL, 4 * 50 * 2, accuracy: 1e-9, "4 点 × $50 × 2 手 = $400")
    }

    // MARK: - 垂直价差(贷记)

    /// 卖 715P 买 710P 的 bull put spread:开仓收钱,到期两腿都作废 → 吃满贷记。
    func testCreditVerticalSpreadKeepsFullCreditWhenBothExpireWorthless() {
        let expiry = Self.t(16, 0)
        let short = Leg(kind: .option(right: .put, strike: 715, expiry: expiry), note: "卖 715P")
        let long  = Leg(kind: .option(right: .put, strike: 710, expiry: expiry), note: "买 710P")
        let t = Trade(symbol: "QQQ", strategy: .verticalSpread, legs: [short, long], fills: [
            Fill(legID: short.id, time: Self.t(10, 0), side: .sell, quantity: 1, price: 2.00, underlying: 718),
            Fill(legID: long.id,  time: Self.t(10, 0), side: .buy,  quantity: 1, price: 0.80, underlying: 718),
        ])
        XCTAssertEqual(t.openingCashFlow, 120, accuracy: 1e-9, "净贷记 $1.20 × 100")
        XCTAssertEqual(t.netCredit, 120, accuracy: 1e-9)
        XCTAssertEqual(t.netDebit, 0, accuracy: 1e-9)
        XCTAssertFalse(t.isClosed, "还没平仓")

        // 标的收在 720,两个 put 都归零 ⇒ 吃满贷记 $120
        let cf = CounterfactualEngine.holdToClose(trade: t, finalUnderlying: 720)
        XCTAssertEqual(cf.alternativePnL, 120, accuracy: 1e-9)

        // 标的跌到 705,价差走到最大宽度 $5 ⇒ 亏 (5 − 1.2) × 100 = $380
        let bad = CounterfactualEngine.holdToClose(trade: t, finalUnderlying: 705)
        XCTAssertEqual(bad.alternativePnL, -380, accuracy: 1e-9, "最大亏损 = 宽度 − 贷记")
    }

    /// 铁鹰:四条腿,到期全在区间内 ⇒ 吃满贷记。
    func testIronCondorFourLegs() {
        let e = Self.t(16, 0)
        let legs = [
            Leg(kind: .option(right: .put,  strike: 700, expiry: e), note: "买 700P"),
            Leg(kind: .option(right: .put,  strike: 710, expiry: e), note: "卖 710P"),
            Leg(kind: .option(right: .call, strike: 730, expiry: e), note: "卖 730C"),
            Leg(kind: .option(right: .call, strike: 740, expiry: e), note: "买 740C"),
        ]
        let px = [0.30, 1.10, 1.20, 0.40]
        let sides: [Side] = [.buy, .sell, .sell, .buy]
        let t = Trade(symbol: "QQQ", strategy: .ironCondor, legs: legs,
                      fills: zip(legs.indices, px).map { i, p in
                          Fill(legID: legs[i].id, time: Self.t(10, 0), side: sides[i],
                               quantity: 1, price: p, underlying: 718) })
        XCTAssertEqual(t.legs.count, 4)
        XCTAssertEqual(t.openingCashFlow, (1.10 + 1.20 - 0.30 - 0.40) * 100, accuracy: 1e-6)
        let cf = CounterfactualEngine.holdToClose(trade: t, finalUnderlying: 720)
        XCTAssertEqual(cf.alternativePnL, 160, accuracy: 1e-6, "区间内全归零,吃满 $1.60 贷记")
    }

    // MARK: - v1 存档必须还能读

    /// ★ 对应差评「Update reset my results」——
    /// 升级后数据没了,几乎总是因为新版本读不动旧格式然后当成空的存了回去。
    /// v1 的存档结构(照抄旧定义),**用它真的编码一份 v1 文件出来** ——
    /// 手写 JSON 会写错格式(我第一次就把 ISO8601 日期写成了数字),而格式写错的测试
    /// 测的是我的记性,不是代码。
    private struct V1Trade: Encodable {
        var id: UUID
        var symbol: String
        var instrument: Instrument
        var isLong: Bool
        var fills: [Fill]
        var exitReason: String?
        var rawNoteAtEntry: String?
    }
    private struct V1File: Encodable { var schemaVersion: Int; var trades: [V1Trade] }

    func testV1ArchiveStillDecodes() throws {
        let expiry = Self.t(16, 0)
        let v1 = V1File(schemaVersion: 1, trades: [
            V1Trade(id: UUID(), symbol: "QQQ",
                    instrument: .option(right: .call, strike: 717, expiry: expiry),
                    isLong: true,
                    fills: [
                        Fill(time: Self.t(10, 30), side: .buy,  quantity: 2, price: 2.17, underlying: 717.24),
                        Fill(time: Self.t(11,  2), side: .sell, quantity: 2, price: 2.51, underlying: 718.04)],
                    exitReason: "触及目标", rawNoteAtEntry: "看涨旗")
        ])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(v1)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("v1-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TradeStore(url: dir.appendingPathComponent("trades.json"))
        try data.write(to: store.url)

        let trades = try store.load()
        XCTAssertEqual(trades.count, 1, "v1 存档必须读得出来,不许当成空的")
        XCTAssertEqual(trades[0].legs.count, 1, "v1 的 instrument 应被转成一条腿")
        XCTAssertTrue(trades[0].legs[0].kind.isOption)
        XCTAssertEqual(trades[0].realizedPnL, (2.51 - 2.17) * 2 * 100, accuracy: 1e-6)
        XCTAssertEqual(trades[0].rawNoteAtEntry, "看涨旗", "用户原话不许在迁移中丢")
        XCTAssertEqual(trades[0].exitReason, "触及目标")

        // 存回 v2 再读一遍,必须还是同一笔(往返不许丢东西)
        try store.save(trades)
        let again = try store.load()
        XCTAssertEqual(again[0].realizedPnL, trades[0].realizedPnL, accuracy: 1e-9)
        XCTAssertEqual(again[0].legs.count, 1)
        XCTAssertEqual(again[0].rawNoteAtEntry, "看涨旗")
    }
}

/// 策略模板的形状。「铁鹰应该是 买P-卖P-卖C-买C」写在测试里,比写在注释里管用。
final class StrategyTemplateTests: XCTestCase {

    func testEveryStrategyProducesLegCountWithinItsDeclaredRange() {
        for k in StrategyKind.allCases {
            let n = StrategyTemplate.drafts(for: k).count
            XCTAssertTrue(k.expectedLegCount.contains(n),
                          "\(k.rawValue) 生成 \(n) 条腿,但声明的是 \(k.expectedLegCount)")
        }
    }

    func testIronCondorShape() {
        let d = StrategyTemplate.drafts(for: .ironCondor)
        XCTAssertEqual(d.map(\.right), [.put, .put, .call, .call])
        XCTAssertEqual(d.map(\.suggestedSide), [.buy, .sell, .sell, .buy], "两卖夹在两买中间")
    }

    func testStraddleIsSameStrikeBothBought() {
        let d = StrategyTemplate.drafts(for: .straddle)
        XCTAssertEqual(d.map(\.right), [.call, .put])
        XCTAssertTrue(d.allSatisfy { $0.suggestedSide == .buy })
    }

    /// 备兑 / 保护性看跌 / 领口 必须含一条**正股**腿,否则算不出真实盈亏。
    func testStrategiesWithEquityLeg() {
        for k in [StrategyKind.coveredCall, .protectivePut, .collar] {
            XCTAssertTrue(StrategyTemplate.hasEquityLeg(k), "\(k.rawValue) 应该有正股腿")
        }
        for k in [StrategyKind.verticalSpread, .ironCondor, .straddle] {
            XCTAssertFalse(StrategyTemplate.hasEquityLeg(k))
        }
    }
}

/// 多腿的反事实必须**逐腿**算 —— 只给第一条腿定价会得出完全错误的数。
final class MultiLegCounterfactualTests: XCTestCase {

    /// 铁鹰:标的收在区间内 → 吃满贷记;收在翼外 → 亏 (宽度 − 贷记)。
    /// 若引擎只看第一条腿(买 700P),两种情形都会算成 0,错得离谱。
    func testIronCondorCounterfactualUsesAllFourLegs() {
        let e = InstrumentCoverageTests.t(16, 0)
        let legs = [
            Leg(kind: .option(right: .put,  strike: 700, expiry: e)),
            Leg(kind: .option(right: .put,  strike: 710, expiry: e)),
            Leg(kind: .option(right: .call, strike: 730, expiry: e)),
            Leg(kind: .option(right: .call, strike: 740, expiry: e)),
        ]
        let sides: [Side] = [.buy, .sell, .sell, .buy]
        let px = [0.30, 1.10, 1.20, 0.40]
        let t = Trade(symbol: "QQQ", strategy: .ironCondor, legs: legs,
                      fills: legs.indices.map { i in
                          Fill(legID: legs[i].id, time: InstrumentCoverageTests.t(10, 0),
                               side: sides[i], quantity: 1, price: px[i], underlying: 718) })

        let inRange = CounterfactualEngine.allByTime(
            trade: t, peakUnderlying: nil, peakTime: nil, finalUnderlying: 720)
        let hold = inRange.results.first { $0.id == "hold_to_close" }
        XCTAssertNotNil(hold)
        XCTAssertEqual(hold!.alternativePnL, 160, accuracy: 1e-6, "区间内 → 吃满 $1.60 贷记")

        let below = CounterfactualEngine.holdToClose(trade: t, finalUnderlying: 695)
        XCTAssertEqual(below.alternativePnL, -(1000 - 160), accuracy: 1e-6,
                       "跌破下翼 → 亏 宽度$10×100 − 贷记$160")
    }

    /// 日历价差:两条腿到期日不同,必须各用各的。
    func testCalendarSpreadUsesPerLegExpiry() {
        let near = InstrumentCoverageTests.t(16, 0, day: 6)
        let far  = InstrumentCoverageTests.t(16, 0, day: 13)
        let l1 = Leg(kind: .option(right: .call, strike: 717, expiry: near))
        let l2 = Leg(kind: .option(right: .call, strike: 717, expiry: far))
        let t = Trade(symbol: "QQQ", strategy: .calendarSpread, legs: [l1, l2], fills: [
            Fill(legID: l1.id, time: InstrumentCoverageTests.t(10, 0, day: 6), side: .sell,
                 quantity: 1, price: 1.50, underlying: 716),
            Fill(legID: l2.id, time: InstrumentCoverageTests.t(10, 0, day: 6), side: .buy,
                 quantity: 1, price: 3.20, underlying: 716),
        ])
        // 各腿 IV 分别反解,且用各自的到期日 —— 近月剩 6 小时,远月剩 7 天
        let vols = CounterfactualEngine.impliedVols(of: t)
        XCTAssertEqual(vols.count, 2, "两条腿都要有自己的 IV")
        XCTAssertNotEqual(vols[l1.id]!, vols[l2.id]!, accuracy: 1e-9,
                          "同行权价、不同到期,反解出的 IV 不该相同")
        XCTAssertEqual(t.openingCashFlow, (1.50 - 3.20) * 100, accuracy: 1e-6, "净借记 $170")
    }

    /// 逐腿盈亏之和必须等于总盈亏。
    func testLegPnLSumsToTotal() {
        let e = InstrumentCoverageTests.t(16, 0)
        let a = Leg(kind: .option(right: .call, strike: 715, expiry: e))
        let b = Leg(kind: .option(right: .call, strike: 720, expiry: e))
        let t = Trade(symbol: "QQQ", strategy: .verticalSpread, legs: [a, b], fills: [
            Fill(legID: a.id, time: InstrumentCoverageTests.t(10, 0), side: .buy,  quantity: 2, price: 4.00, underlying: 716),
            Fill(legID: b.id, time: InstrumentCoverageTests.t(10, 0), side: .sell, quantity: 2, price: 1.80, underlying: 716),
            Fill(legID: a.id, time: InstrumentCoverageTests.t(14, 0), side: .sell, quantity: 2, price: 5.50, underlying: 719),
            Fill(legID: b.id, time: InstrumentCoverageTests.t(14, 0), side: .buy,  quantity: 2, price: 2.60, underlying: 719),
        ])
        XCTAssertEqual(t.legPnL(a) + t.legPnL(b), t.realizedPnL, accuracy: 1e-9)
        XCTAssertEqual(t.legPnL(a),  300, accuracy: 1e-6, "买腿 4.00→5.50 × 2 = +$300")
        XCTAssertEqual(t.legPnL(b), -160, accuracy: 1e-6, "卖腿 1.80→2.60 × 2 = −$160")
        XCTAssertEqual(t.realizedPnL, 140, accuracy: 1e-6)
        XCTAssertEqual(t.legEntry(a), 4.00, accuracy: 1e-9)
        XCTAssertEqual(t.legEntry(b), 1.80, accuracy: 1e-9, "卖腿的入场是卖出价")
        XCTAssertTrue(t.isClosed)
    }
}
