import XCTest
@testable import ReviewEngine

/// 按交易种类分类。★ 守两件事:**分组正确** + **只有一类的维度不显示**。
final class KindStatsTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TradingDay.exchangeTimeZone
        return c
    }
    private func at(_ d: Int, _ h: Int = 10) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = d; c.hour = h
        c.timeZone = TradingDay.exchangeTimeZone
        return cal.date(from: c)!
    }

    private func trade(_ kind: LegKind, day: Int = 6, side: Side = .buy,
                       entry: Double = 1, exit: Double? = 2,
                       symbol: String = "QQQ",
                       strategy: StrategyKind = .single) -> Trade {
        let leg = Leg(kind: kind)
        var fills = [Fill(legID: leg.id, time: at(day), side: side,
                          quantity: 1, price: entry)]
        if let exit {
            fills.append(Fill(legID: leg.id, time: at(day, 11),
                              side: side == .buy ? .sell : .buy,
                              quantity: 1, price: exit))
        }
        return Trade(symbol: symbol, strategy: strategy, legs: [leg], fills: fills)
    }

    private let call = LegKind.option(right: .call, strike: 700, expiry: Date())
    private let put  = LegKind.option(right: .put, strike: 700, expiry: Date())
    private let fut  = LegKind.futures(contract: "MNQ", pointValue: 2, tickSize: 0.25)

    // ── 只有一类的维度不显示 ─────────────────────────────────────────

    func testSingleValuedDimensionIsHidden() {
        // 全是期权、全是买 Call、全是单腿、全是 QQQ ⇒ 一个分组都不该出现
        let g = KindStats.groups([trade(call), trade(call, day: 5)])
        XCTAssertTrue(g.isEmpty, "★ 一个格子没有对比,画出来只是占地方:\(g.map(\.title))")
    }

    func testInstrumentGroupAppearsWhenMixed() {
        let g = KindStats.groups([trade(call), trade(.equity), trade(fut)])
        let inst = g.first { $0.title == "品种" }
        XCTAssertNotNil(inst)
        XCTAssertEqual(Set(inst!.buckets.map(\.label)), ["期权", "股票/ETF", "期货"])
    }

    // ── 方向:期权说 Call/Put,线性品种说 多/空 ────────────────────────

    func testOptionDirectionSaysCallPutAndBuySell() {
        let g = KindStats.groups([trade(call, side: .buy), trade(put, side: .buy),
                                  trade(call, day: 5, side: .sell)])
        let dir = g.first { $0.title == "方向" }!
        XCTAssertEqual(Set(dir.buckets.map(\.label)), ["买 Call", "买 Put", "卖 Call"])
    }

    func testLinearDirectionSaysLongShort() {
        let g = KindStats.groups([trade(.equity, side: .buy),
                                  trade(.equity, day: 5, side: .sell)])
        let dir = g.first { $0.title == "方向" }!
        XCTAssertEqual(Set(dir.buckets.map(\.label)), ["做多", "做空"])
    }

    func testDirectionComesFromTheFirstFillNotAField() {
        // ★ 「做空」由首笔是卖决定 —— 不看任何「方向」字段
        let short = trade(.equity, side: .sell, entry: 10, exit: 8)   // 卖 10 买回 8 = 赚
        XCTAssertEqual(KindStats.direction(short), "做空")
        XCTAssertEqual(short.realizedPnL, 2, accuracy: 1e-9)
    }

    // ── 数字 ──────────────────────────────────────────────────────

    func testPnLAndWinsPerBucket() {
        let g = KindStats.groups([
            trade(call, entry: 1, exit: 2),        // +100
            trade(call, day: 5, entry: 2, exit: 1), // −100
            trade(.equity, entry: 10, exit: 12),    // +2
        ])
        let inst = g.first { $0.title == "品种" }!
        let opt = inst.buckets.first { $0.label == "期权" }!
        XCTAssertEqual(opt.n, 2)
        XCTAssertEqual(opt.wins, 1)
        XCTAssertEqual(opt.pnl, 0, accuracy: 0.01)
        XCTAssertEqual(opt.winRate, 0.5, accuracy: 1e-9)
    }

    func testSortedByPnLDescending() {
        let g = KindStats.groups([
            trade(call, entry: 1, exit: 5),        // +400
            trade(.equity, entry: 10, exit: 11),   // +1
        ])
        XCTAssertEqual(g.first { $0.title == "品种" }!.buckets.first?.label, "期权")
    }

    func testOpenTradesCountedSeparately() {
        let g = KindStats.groups([trade(call, exit: nil), trade(.equity)])
        let opt = g.first { $0.title == "品种" }!.buckets.first { $0.label == "期权" }!
        XCTAssertEqual(opt.n, 0)
        XCTAssertEqual(opt.openCount, 1, "未平仓不进盈亏,但要能看见")
    }

    func testSamplesExcluded() {
        var s = trade(call); s.isSample = true
        XCTAssertTrue(KindStats.groups([s, trade(.equity)]).isEmpty,
                      "剔掉示例后只剩一类 ⇒ 不该出现任何分组")
    }

    func testStrategyGroupOnlyWhenMoreThanOneUsed() {
        XCTAssertNil(KindStats.groups([trade(call), trade(call, day: 5)])
                        .first { $0.title == "策略" })
        let mixed = KindStats.groups([trade(call, strategy: .single),
                                      trade(call, day: 5, strategy: .ironCondor)])
        XCTAssertNotNil(mixed.first { $0.title == "策略" })
    }

    func testSymbolGroup() {
        let g = KindStats.groups([trade(call, symbol: "QQQ"),
                                  trade(call, day: 5, symbol: "SPY")])
        XCTAssertEqual(Set(g.first { $0.title == "标的" }!.buckets.map(\.label)),
                       ["QQQ", "SPY"])
    }

    // ── ★ 和周期口径必须一致 ───────────────────────────────────────

    func testKindBreakdownUsesTheSamePeriodRule() {
        // 8/31 开、9/2 平 -> 属于 9/2 那一格。分类必须跟着走,
        // 否则上面写「9/2 一笔」、下面按品种加起来是 0 笔 —— 用户一眼就看出打架。
        var c = DateComponents(); c.timeZone = TradingDay.exchangeTimeZone
        c.year = 2026; c.month = 8; c.day = 31; c.hour = 15
        let open = cal.date(from: c)!
        c.month = 9; c.day = 2; c.hour = 10
        let close = cal.date(from: c)!
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: open, side: .buy, quantity: 1, price: 10),
            Fill(legID: leg.id, time: close, side: .sell, quantity: 1, price: 12),
        ])
        let s = PeriodStats.compute([t], period: .day, now: close)
        let inBucket = PeriodStats.trades([t], in: s.displayed, period: .day)
        XCTAssertEqual(inBucket.count, 1, "★ 归期规则必须和大号数字完全一致")
        XCTAssertEqual(PeriodStats.trades([t], in: PeriodBucket(
            key: "2026-08-31", label: "", start: open, n: 0, wins: 0, pnl: 0,
            openCount: 0, bestAlternativeDelta: nil, bestAlternativeLabel: nil),
            period: .day).count, 0, "开仓那天不该算")
    }
}

/// ★★ 「自动隐藏」把功能藏没了。
/// 2026-09-02 用户:「我手机上怎么没有按种类看」——
/// 他停在「日」,那天只有一笔,所有维度都单值,于是**整栏连入口一起消失**。
/// 一个自动隐藏的功能,和一个坏掉的功能,从用户那边看没有区别。
final class KindVisibilityTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TradingDay.exchangeTimeZone
        return c
    }
    private func at(_ d: Int, _ h: Int = 10) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = d; c.hour = h
        c.timeZone = TradingDay.exchangeTimeZone
        return cal.date(from: c)!
    }
    private func optTrade(day: Int = 6) -> Trade {
        let leg = Leg(kind: .option(right: .call, strike: 700, expiry: at(day, 16)))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: at(day), side: .buy, quantity: 1, price: 1),
            Fill(legID: leg.id, time: at(day, 11), side: .sell, quantity: 1, price: 2),
        ])
    }

    func testSingleTradeStillProducesSomethingToShow() {
        // ★ 一笔交易:没有任何维度能对比,但**不能什么都不给**
        let bd = KindStats.breakdown([optTrade()])
        XCTAssertTrue(bd.groups.isEmpty, "确实没有可对比的维度")
        XCTAssertFalse(bd.isEmpty, "★ 但整体不能是空的 —— 否则入口会消失")
        XCTAssertEqual(bd.n, 1)
        XCTAssertTrue(bd.singles.contains { $0.contains("品种") && $0.contains("期权") },
                      "单值维度该降级成一行摘要:\(bd.singles)")
    }

    func testSinglesCoverEveryDimension() {
        let bd = KindStats.breakdown([optTrade()])
        for dim in ["品种", "方向", "策略", "标的"] {
            XCTAssertTrue(bd.singles.contains { $0.hasPrefix(dim + ":") },
                          "★ \(dim) 也该有一行摘要,而不是消失:\(bd.singles)")
        }
    }

    func testMixedDataStillGetsFullGroups() {
        let stock = Trade(symbol: "BEX", strategy: .single,
                          legs: [Leg(kind: .equity)], fills: [])
        var s = stock
        let leg = s.legs[0]
        s.fills = [Fill(legID: leg.id, time: at(5), side: .buy, quantity: 1, price: 10)]
        let bd = KindStats.breakdown([optTrade(), s])
        XCTAssertFalse(bd.groups.isEmpty)
        XCTAssertTrue(bd.groups.contains { $0.title == "品种" })
    }

    func testNoTradesMeansTrulyEmpty() {
        // 真的一笔都没有时才该整栏消失 —— 那时候「按种类看」确实无从谈起
        XCTAssertTrue(KindStats.breakdown([]).isEmpty)
    }

    func testSamplesDoNotKeepTheSectionAlive() {
        var s = optTrade(); s.isSample = true
        XCTAssertTrue(KindStats.breakdown([s]).isEmpty,
                      "示例不算数 —— 不该靠它撑出一个空栏目")
    }

    func testLegacyGroupsAPIStillReturnsOnlyComparableDimensions() {
        XCTAssertTrue(KindStats.groups([optTrade()]).isEmpty)
    }
}
