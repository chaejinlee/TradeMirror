import XCTest
@testable import ReviewEngine

/// 导出 / 备份 / 导回。
/// ★ 这一组测试守的全是**在 Excel 里才会暴露、在 App 里看不出来**的坑。
final class ExporterTests: XCTestCase {

    private func trade(day: Int, buy: Double, sell: Double?, qty: Double = 3,
                       note: String? = nil, sample: Bool = false) -> Trade {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day
        c.hour = 16; c.timeZone = TradingDay.exchangeTimeZone
        let cal = Calendar(identifier: .gregorian)
        let e = cal.date(from: c)!
        let leg = Leg(kind: .option(right: .call, strike: 708, expiry: e))
        var t0 = c; t0.hour = 10; t0.minute = 13
        var t1 = c; t1.hour = 10; t1.minute = 35
        var fills = [Fill(legID: leg.id, time: cal.date(from: t0)!, side: .buy,
                          quantity: qty, price: buy, underlying: 709.94)]
        if let s = sell {
            fills.append(Fill(legID: leg.id, time: cal.date(from: t1)!, side: .sell,
                              quantity: qty, price: s, underlying: 710.20))
        }
        var t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: fills,
                      peakUnderlying: 712, finalUnderlying: 709.5)
        t.rawNoteAtEntry = note
        t.isSample = sample
        return t
    }

    private func rows(_ csv: String) -> [String] {
        csv.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    // ── 在 Excel 里才会暴露的坑 ──────────────────────────────────────────

    func testHasBOMSoExcelDoesNotGarbleChinese() {
        // 没有 BOM,Excel 打开中文备注是乱码 —— 一个字节的事
        XCTAssertTrue(Exporter.csv([trade(day: 1, buy: 1, sell: 2)]).hasPrefix("\u{FEFF}"))
    }

    func testTradeLevelPnLAppearsOnceNotOnEveryFill() {
        // ★ 最要命的一条:盈亏若每行都写,用户在 Excel 里求和会得到 N 倍
        let csv = Exporter.csv([trade(day: 1, buy: 1.00, sell: 2.00, qty: 3)])
        let body = rows(csv).dropFirst()
        XCTAssertEqual(body.count, 2, "两笔成交 = 两行")
        let header = rows(csv)[0].components(separatedBy: ",")
        let idx = header.firstIndex(of: "realized_pnl")!
        let vals = body.map { $0.components(separatedBy: ",")[idx] }
        XCTAssertEqual(vals[0], "300", "净现金流 (2−1)×3×100")
        XCTAssertEqual(vals[1], "", "★ 第二行必须留空,否则求和是 2 倍")
    }

    func testOpenTradeExportsBlankPnLNotZero() {
        // 未平仓写 0 会被 Excel 当成「打平」,和 App 里的规则要一致
        let csv = Exporter.csv([trade(day: 1, buy: 1.00, sell: nil)])
        let header = rows(csv)[0].components(separatedBy: ",")
        let idx = header.firstIndex(of: "realized_pnl")!
        XCTAssertEqual(rows(csv)[1].components(separatedBy: ",")[idx], "")
    }

    func testNotesWithCommasQuotesAndNewlinesSurvive() {
        // user_raw 是逐字保留的,里面什么都可能有
        let nasty = "买早了,\"追高\"\n第二行"
        let csv = Exporter.csv([trade(day: 1, buy: 1, sell: 2, note: nasty)])
        XCTAssertTrue(csv.contains("\"买早了,\"\"追高\"\"\n第二行\""),
                      "逗号/引号/换行都要按 RFC4180 转义")
        // 转义后行数不变(换行被包在引号里)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 3)
    }

    func testFormulaInjectionIsNeutralised() {
        // 备注可能来自 OCR / 券商文本,不能假定安全
        XCTAssertEqual(Exporter.field("=1+1"), "'=1+1")
        XCTAssertEqual(Exporter.field("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(Exporter.field("+risky"), "'+risky")
        // 但真的负数不能被加引号毁掉
        XCTAssertEqual(Exporter.field("-434.5"), "-434.5")
    }

    func testSampleTradeIsNotExported() {
        // 备份是**用户的**数据,不该混进我编的那笔
        let csv = Exporter.csv([trade(day: 1, buy: 1, sell: 2),
                                trade(day: 2, buy: 1, sell: 2, sample: true)])
        XCTAssertEqual(rows(csv).count, 3, "只有真实那笔的两行 + 表头")
    }

    // ── 备份必须能导回来 ────────────────────────────────────────────────

    func testBackupRoundTripsLosslessly() throws {
        let ts = [trade(day: 1, buy: 1.34, sell: 2.41, note: "计划:跌到 707 进"),
                  trade(day: 2, buy: 2.00, sell: nil)]
        var rules = TradingRules(); rules.maxConsecutiveLosses = 3
        let data = try Exporter.backup(trades: ts, plans: [], closes: .init(), rules: rules)
        let back = try Importer.read(data)
        XCTAssertEqual(back.trades.count, 2)
        XCTAssertEqual(back.trades.map(\.id), ts.map(\.id))
        XCTAssertEqual(back.trades[0].rawNoteAtEntry, "计划:跌到 707 进")
        XCTAssertEqual(back.trades[0].realizedPnL, ts[0].realizedPnL, accuracy: 1e-9)
        XCTAssertEqual(back.rules.maxConsecutiveLosses, 3, "规则也要跟着走")
    }

    func testImportNeverOverwrites() throws {
        // ★「Update reset my results」是竞品差评里最狠的一条
        let a = trade(day: 1, buy: 1, sell: 2)
        let b = trade(day: 2, buy: 3, sell: 4)
        let data = try Exporter.backup(trades: [a, b], plans: [], closes: .init(), rules: .init())
        let r = Importer.merge(try Importer.read(data), into: [a])
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.skipped, 1, "同 id 跳过,不覆盖")
        XCTAssertEqual(r.trades.count, 2)
    }

    func testGarbageFileIsRejectedNotSilentlyEmptied() {
        XCTAssertThrowsError(try Importer.read(Data("这不是备份".utf8))) {
            XCTAssertEqual($0 as? Importer.Failure, .notABackup)
        }
        // 半个 JSON 也要拒
        XCTAssertThrowsError(try Importer.read(Data(#"{"trades":"#.utf8)))
    }

    func testFutureSchemaIsRefusedRatherThanMisread() throws {
        var f = StoreFile(trades: [], pendingPlans: [], dailyCloses: .init(), rules: .init())
        f.schemaVersion = TradeStore.currentSchemaVersion + 5
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try Importer.read(try e.encode(f))) {
            XCTAssertEqual($0 as? Importer.Failure,
                           .futureSchema(found: TradeStore.currentSchemaVersion + 5,
                                         supported: TradeStore.currentSchemaVersion))
        }
    }

    func testFilenameCarriesDateBecauseUsersKeepSeveral() {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 1
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(Exporter.filename(ext: "csv", now: d), "复盘镜-2026-09-01.csv")
    }
}
