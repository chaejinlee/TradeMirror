import XCTest
@testable import ReviewEngine

/// 图表附件。用户截的图里 2/3 是图表(TradingView 标的图 / Webull 期权图),
/// 它们没有成交明细,但它们是「开仓那一刻我看到的东西」。
final class AttachmentTests: XCTestCase {

    private func tempStores() -> (TradeStore, AttachmentStore) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("att-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (TradeStore(url: dir.appendingPathComponent("trades.json")),
                AttachmentStore(directory: dir.appendingPathComponent("attachments")))
    }

    func testSaveLoadDelete() throws {
        let (_, att) = tempStores()
        let data = Data("fake-png-bytes".utf8)
        let a = try att.save(data, ext: "png", caption: "开仓时的 2 分图")
        XCTAssertEqual(att.load(a), data)
        XCTAssertEqual(a.caption, "开仓时的 2 分图")
        att.delete(a)
        XCTAssertNil(att.load(a))
    }

    /// ★ 只存**文件名**不存路径。iOS 重装/迁移后容器 UUID 会变,
    /// 存绝对路径的话图会全部失联 —— 这是很多 App「换手机图片全没了」的原因。
    func testStoresFilenameNotAbsolutePath() throws {
        let (_, att) = tempStores()
        let a = try att.save(Data("x".utf8))
        XCTAssertFalse(a.filename.contains("/"), "存的必须是文件名,不能含路径分隔符")
        XCTAssertFalse(a.filename.contains("Containers"))
    }

    func testAttachmentSurvivesRoundTripThroughStore() throws {
        let (store, att) = tempStores()
        let a = try att.save(Data("chart".utf8), ext: "jpg", caption: "看涨旗")
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                      fills: [Fill(legID: leg.id, time: Date(), side: .buy,
                                   quantity: 1, price: 1, underlying: 1)],
                      attachments: [a])
        try store.save([t])
        let back = try store.load()
        XCTAssertEqual(back[0].attachments.count, 1)
        XCTAssertEqual(back[0].attachments[0].caption, "看涨旗")
        XCTAssertEqual(att.load(back[0].attachments[0]), Data("chart".utf8))
    }

    /// ★ v2 存档(没有 attachments 字段)必须照样读得出来,不能因为新字段就读不动。
    /// 对应竞品差评「Update reset my results」。
    func testV2ArchiveWithoutAttachmentsStillLoads() throws {
        let (store, _) = tempStores()
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                      fills: [Fill(legID: leg.id, time: Date(), side: .buy,
                                   quantity: 1, price: 1, underlying: 1)])
        try store.save([t])
        // 手动把 schemaVersion 改回 2 并删掉 attachments 键,模拟旧存档
        var raw = try String(contentsOf: store.url, encoding: .utf8)
        raw = raw.replacingOccurrences(of: "\"schemaVersion\" : 3", with: "\"schemaVersion\" : 2")
        try raw.write(to: store.url, atomically: true, encoding: .utf8)
        let back = try store.load()
        XCTAssertEqual(back.count, 1)
        XCTAssertTrue(back[0].attachments.isEmpty, "旧存档没有附件是正常的,不该报错")
    }

    /// 删了交易但忘了删图 → 孤儿文件会让磁盘一直涨。
    func testPruneOrphansRemovesUnreferencedFiles() throws {
        let (_, att) = tempStores()
        let keep = try att.save(Data("keep".utf8))
        _ = try att.save(Data("orphan1".utf8))
        _ = try att.save(Data("orphan2".utf8))
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                      fills: [Fill(legID: leg.id, time: Date(), side: .buy,
                                   quantity: 1, price: 1, underlying: 1)],
                      attachments: [keep])
        XCTAssertEqual(att.pruneOrphans(referencedBy: [t]), 2, "两个孤儿该被清掉")
        XCTAssertNotNil(att.load(keep), "被引用的不许删")
    }
}

/// 2026-09-01 用户实测反馈「填数字好烦」之后的改动。
final class OptionalUnderlyingTests: XCTestCase {

    /// 线性品种:标的价 == 成交价,不该要求用户填。
    func testLinearInstrumentDerivesUnderlyingFromPrice() {
        let leg = Leg(kind: .equity)
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: Date(), side: .buy, quantity: 100, price: 709.94)])
        XCTAssertEqual(t.effectiveUnderlying(of: t.fills[0]), 709.94, "股票不填也该有值")
        XCTAssertFalse(t.missingExitUnderlying)
    }

    /// 期权开仓不填标的价 —— 完全不影响,因为引擎只在出场那笔用它。
    func testOptionEntryWithoutUnderlyingIsFine() {
        let e = InstrumentCoverageTests.t(16, 0)
        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: e))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: InstrumentCoverageTests.t(10, 13), side: .buy,
                 quantity: 3, price: 1.34),                       // 没填标的价
            Fill(legID: leg.id, time: InstrumentCoverageTests.t(10, 35), side: .sell,
                 quantity: 3, price: 2.41, underlying: 710.20)])  // 只有出场填了
        XCTAssertEqual(t.realizedPnL, 321, accuracy: 1e-6)
        XCTAssertFalse(t.missingExitUnderlying, "出场填了就够")
        XCTAssertNotNil(CounterfactualEngine.impliedVolAtExit(trade: t, hoursToExpiryAtExit: 5.4))
    }

    /// ★ 出场也没填 ⇒ 只少「若在峰值出场」,**其余三条照常算**。
    func testMissingExitUnderlyingOnlyCostsThePeakCounterfactual() {
        let e = InstrumentCoverageTests.t(16, 0)
        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: e))
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: InstrumentCoverageTests.t(10, 13), side: .buy,  quantity: 3, price: 1.34),
            Fill(legID: leg.id, time: InstrumentCoverageTests.t(10, 35), side: .sell, quantity: 3, price: 2.41)])
        XCTAssertTrue(t.missingExitUnderlying, "界面要据此明确告诉用户少了哪一条")
        XCTAssertNil(CounterfactualEngine.impliedVolAtExit(trade: t, hoursToExpiryAtExit: 5.4))

        let r = CounterfactualEngine.allByTime(trade: t, peakUnderlying: 712,
                                               peakTime: nil, finalUnderlying: 709.5)
        let ids = Set(r.results.map(\.id))
        XCTAssertTrue(ids.contains("hold_to_close"), "持有到收盘照常")
        XCTAssertTrue(ids.contains("scale_out_hold"), "平一半照常")
        XCTAssertTrue(ids.contains("no_add_on") || !t.buys.count.isMultiple(of: 2), "不加仓照常(无加仓则不出现)")
        XCTAssertFalse(ids.contains("exit_vs_peak"), "★ 只有峰值这一条算不了")
        XCTAssertTrue(r.missing.contains(.userProvidedPeak))
    }
}
