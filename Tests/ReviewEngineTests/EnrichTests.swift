import XCTest
@testable import ReviewEngine

/// 「补空」和「覆盖」是两件事。
/// ★ 起因:v1.5 的 `tools/moomoo_enrich.py` 在电脑上用 moomoo 查到期权的**真实**收盘价
///   (手机连不到 OpenD),再导回来。若沿用「同 id 一律跳过」,补好的数据永远进不来;
///   若改成整笔替换,又会毁掉用户手填的东西。**只填 nil,是唯一两边都对的做法。**
final class EnrichTests: XCTestCase {

    private func trade(id: UUID, legID: UUID, close: Double? = nil,
                       userClose: Double? = nil, peak: Double? = nil) -> Trade {
        var leg = Leg(id: legID, kind: .option(right: .call, strike: 708, expiry: Date()))
        leg.userClosePrice = userClose
        return Trade(id: id, symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: legID, time: Date(), side: .buy, quantity: 3, price: 1.34),
            Fill(legID: legID, time: Date().addingTimeInterval(600), side: .sell,
                 quantity: 3, price: 2.41),
        ], peakUnderlying: peak, finalUnderlying: close)
    }

    private func file(_ ts: [Trade]) -> StoreFile {
        StoreFile(trades: ts, pendingPlans: [], dailyCloses: .init(), rules: .init())
    }

    func testBlanksGetFilled() {
        let id = UUID(), leg = UUID()
        let mine = trade(id: id, legID: leg)                                   // 全空
        let enriched = trade(id: id, legID: leg, close: 707.64,
                             userClose: 0.25, peak: 712.30)                    // moomoo 补过
        let r = Importer.merge(file([enriched]), into: [mine])
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.skipped, 1, "同 id 不新增")
        XCTAssertEqual(r.enrichedFields, 3, "收盘价 + 峰值 + 期权真实价")
        XCTAssertEqual(r.enrichedTrades, 1)
        XCTAssertEqual(r.trades.first?.finalUnderlying, 707.64)
        XCTAssertEqual(r.trades.first?.legs.first?.userClosePrice, 0.25)
    }

    func testMyOwnValuesAreNeverTouched() {
        // ★ 这是这条特性的底线:我填过的,谁也别动
        let id = UUID(), leg = UUID()
        let mine = trade(id: id, legID: leg, close: 999, userClose: 0.99, peak: 888)
        let enriched = trade(id: id, legID: leg, close: 707.64, userClose: 0.25, peak: 712.30)
        let r = Importer.merge(file([enriched]), into: [mine])
        XCTAssertEqual(r.enrichedFields, 0, "一个字段都不该被改")
        XCTAssertEqual(r.trades.first?.finalUnderlying, 999)
        XCTAssertEqual(r.trades.first?.peakUnderlying, 888)
        XCTAssertEqual(r.trades.first?.legs.first?.userClosePrice, 0.99)
    }

    func testPartialFillOnlyTouchesTheBlankOne() {
        let id = UUID(), leg = UUID()
        let mine = trade(id: id, legID: leg, close: 707.64)          // 收盘价我填了
        let enriched = trade(id: id, legID: leg, close: 700, userClose: 0.25)
        let r = Importer.merge(file([enriched]), into: [mine])
        XCTAssertEqual(r.enrichedFields, 1, "只补期权价那一个")
        XCTAssertEqual(r.trades.first?.finalUnderlying, 707.64, "我填的 707.64 必须留着")
        XCTAssertEqual(r.trades.first?.legs.first?.userClosePrice, 0.25)
    }

    func testBrandNewTradesStillGetAdded() {
        // ★ 「新」的判据是**内容不同**,不是 id 不同。
        //   (2026-09-02:原来这个测试造的两笔成交完全一样、只是 id 不同 ——
        //    那本来就该被认成同一笔。改成价格真的不一样。)
        let a = trade(id: UUID(), legID: UUID())
        var b = trade(id: UUID(), legID: UUID(), close: 707.64)
        b.fills[0].price = 9.99          // 真的是另一笔
        let r = Importer.merge(file([a, b]), into: [a])
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.trades.count, 2)
    }

    func testIdenticalContentWithDifferentIDsIsNotANewTrade() {
        // ★★ 这条直接盯住 2026-09-02 那次事故:
        //   我重新生成了一次导入文件,里面每笔的 id 全都变了,
        //   用户一导入 —— **5 笔变 10 笔**。
        //   现在:内容一样就是同一笔,不管 id 是什么。
        let mine = trade(id: UUID(), legID: UUID())
        var reissued = mine
        reissued.id = UUID()                          // 脚本重跑,换了 id
        reissued.legs[0].id = UUID()
        for i in reissued.fills.indices { reissued.fills[i].id = UUID() }
        let r = Importer.merge(file([reissued]), into: [mine])
        XCTAssertEqual(r.added, 0, "★ 不许因为 id 换了就当成新的一笔")
        XCTAssertEqual(r.trades.count, 1)
    }

    func testLegMatchedByContractWhenIDsDiffer() {
        // ⚠️ 意图变更(2026-09-02):这条原来断言「腿 id 对不上就不填」。
        //   那个断言建立在「id 就是身份」这个假设上 —— 而那正是今天出事故的假设。
        //   同一份合约(同 right/strike/expiry)就是同一条腿,该补。
        let id = UUID(), l1 = UUID(), l2 = UUID()
        let mine = trade(id: id, legID: l1)
        var other = trade(id: id, legID: l2, userClose: 0.25)
        other.legs[0].id = l2
        let r = Importer.merge(file([other]), into: [mine])
        XCTAssertEqual(r.trades.first?.legs.first?.userClosePrice, 0.25,
                       "合约一样就是同一条腿 —— id 是造的,合约才是真的")
    }

    func testDifferentContractStillDoesNotGetFilled() {
        // 但合约不一样就绝不能塞 —— 708C 的收盘价不许填到 715C 上
        let id = UUID(), l1 = UUID()
        let mine = trade(id: id, legID: l1)
        var other = trade(id: id, legID: UUID(), userClose: 0.25)
        other.legs[0].kind = .option(right: .call, strike: 715, expiry: Date())
        let r = Importer.merge(file([other]), into: [mine])
        XCTAssertNil(r.trades.first?.legs.first?.userClosePrice)
    }
}

/// ★★ 存档兼容性。加一个字段就让**所有旧存档整份读不出来** —— 2026-09-01 实测踩过。
final class SchemaCompatTests: XCTestCase {

    private func load(_ json: String) throws -> (trades: [Trade], rules: TradingRules) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        let a = try TradeStore(url: url).loadAll()
        return (a.trades, a.rules)
    }

    func testV9RulesWithoutTrailingStopPctStillLoads() throws {
        // 这是**真实的旧存档格式**:rules 里没有 trailingStopPct
        let r = try load("""
        {"schemaVersion":9,"trades":[],
         "rules":{"coolDownMinutesAfterLoss":15,"dailyLossLimitPct":3,"enabled":true,
                  "maxConsecutiveLosses":3,"minConfidence":4}}
        """)
        XCTAssertEqual(r.rules.trailingStopPct, 25, "缺字段要落到默认值,不能整份失败")
        XCTAssertEqual(r.rules.minConfidence, 4, "其余字段照常读进来")
    }

    func testCompletelyEmptyRulesObjectStillLoads() throws {
        let r = try load(#"{"schemaVersion":8,"trades":[],"rules":{}}"#)
        XCTAssertEqual(r.rules.minConfidence, TradingRules().minConfidence)
        XCTAssertTrue(r.rules.enabled)
    }

    func testLegWithoutPathOrClosePriceStillLoads() throws {
        let leg = UUID(), fill = UUID()
        let r = try load("""
        {"schemaVersion":8,"trades":[{"id":"\(UUID().uuidString)","symbol":"QQQ",
        "strategy":"单腿","legs":[{"id":"\(leg.uuidString)","kind":{"equity":{}}}],
        "fills":[{"id":"\(fill.uuidString)","legID":"\(leg.uuidString)","price":100,
        "quantity":1,"side":"buy","time":"2026-09-01T14:13:00Z"}]}]}
        """)
        XCTAssertEqual(r.trades.count, 1)
        XCTAssertNil(r.trades[0].legs[0].path)
        XCTAssertNil(r.trades[0].legs[0].userClosePrice)
    }
}
