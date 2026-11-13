import XCTest
@testable import ReviewEngine

/// 每天自动备份的**纯逻辑**:叫什么名、哪份最新、留几份、今天要不要写。
///
/// ★★ 用户 2026-09-03:「每天自动备份到 iCloud,重装之后也能自动识别最新备份」。
///   「选文件夹 / 写文件」那一层是系统 API,测不了;
///   但**「哪份是最新的」「该删哪些」这类判断可以测,而且必须测** ——
///   选错一份去恢复、或者删错一个文件,都是不可逆的。
final class BackupRotationTests: XCTestCase {

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        c.hour = h; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // ── 命名 ────────────────────────────────────────────────────────

    /// ★ 自动备份和手动导出必须**同一套命名** ——
    ///   两套命名意味着「最新的一份」会漏掉另一套里的文件。
    func testAutoBackupUsesTheSameNameAsManualExport() {
        let d = at(2026, 9, 3)
        XCTAssertEqual(BackupRotation.fileName(for: d), Exporter.filename(ext: "json", now: d))
        XCTAssertEqual(BackupRotation.fileName(for: d), "复盘镜-2026-09-03.json")
    }

    func testDateRoundTripsThroughTheFileName() {
        let d = at(2026, 9, 3)
        let back = BackupRotation.date(fromFileName: BackupRotation.fileName(for: d))
        XCTAssertEqual(TradingDay.key(of: try XCTUnwrap(back)), "2026-09-03")
    }

    func testUnparseableNamesGiveNil() {
        XCTAssertNil(BackupRotation.date(fromFileName: "备份.json"))
        XCTAssertNil(BackupRotation.date(fromFileName: "trades.json"))
    }

    // ── 哪份最新 ────────────────────────────────────────────────────

    func testLatestPicksTheNewestDate() {
        let names = ["复盘镜-2026-08-31.json", "复盘镜-2026-09-03.json", "复盘镜-2026-09-01.json"]
        XCTAssertEqual(BackupRotation.latest(among: names), "复盘镜-2026-09-03.json")
    }

    /// ★★ 认不出日期的文件**不参与** —— 宁可不选,也不要拿一份
    ///   不知道是什么时候的文件去覆盖用户当前的数据。
    func testUndatedFilesNeverWin() {
        let names = ["随手存的.json", "复盘镜-2026-09-01.json"]
        XCTAssertEqual(BackupRotation.latest(among: names), "复盘镜-2026-09-01.json")
        XCTAssertNil(BackupRotation.latest(among: ["随手存的.json", "backup.json"]))
    }

    func testLatestOfNothingIsNil() {
        XCTAssertNil(BackupRotation.latest(among: []))
    }

    // ── 留几份 ──────────────────────────────────────────────────────

    func testKeepsTheMostRecentNAndReturnsTheRest() {
        let names = (1...40).map { "复盘镜-2026-08-\(String(format: "%02d", min($0, 31))).json" }
        let uniq = Array(Set(names))
        let expired = BackupRotation.expired(among: uniq, keep: 10)
        XCTAssertEqual(uniq.count - expired.count, 10)
        // 留下来的必须是**最新的** 10 天
        let kept = Set(uniq).subtracting(expired)
        XCTAssertTrue(kept.contains("复盘镜-2026-08-31.json"))
        XCTAssertFalse(kept.contains("复盘镜-2026-08-01.json"))
    }

    func testNothingExpiresBelowTheLimit() {
        let names = ["复盘镜-2026-09-01.json", "复盘镜-2026-09-02.json"]
        XCTAssertTrue(BackupRotation.expired(among: names, keep: 30).isEmpty)
    }

    /// ★★ 认不出日期的**一律不删**。删错文件不可逆,
    ///   而多留几个文件的代价只是几十 KB。
    func testUndatedFilesAreNeverDeleted() {
        var names = (1...31).map { "复盘镜-2026-08-\(String(format: "%02d", $0)).json" }
        names.append("我自己另存的重要备份.json")
        let expired = BackupRotation.expired(among: names, keep: 5)
        XCTAssertFalse(expired.contains("我自己另存的重要备份.json"))
    }

    // ── 日期在未来的文件 ────────────────────────────────────────────

    /// ★★ 用户 iCloud 备份文件夹 2026-10-03 的**真实清单**。最后那份是「立刻备份一次」
    ///   把 `now` 冒充成 `.distantFuture` 写出来的(v3.7 起就这样,按一次覆盖一次)。
    static let realFolder = [
        "复盘镜-2026-09-03.json", "复盘镜-2026-09-04.json", "复盘镜-2026-09-05.json",
        "复盘镜-2026-09-06.json", "复盘镜-2026-09-09.json", "复盘镜-2026-09-15.json",
        "复盘镜-2026-09-18.json", "复盘镜-2026-09-21.json", "复盘镜-2026-09-22.json",
        "复盘镜-2026-09-23.json", "复盘镜-2026-09-24.json", "复盘镜-2026-09-25.json",
        "复盘镜-2026-09-30.json", "复盘镜-2026-10-01.json", "复盘镜-2026-10-02.json",
        "复盘镜-2026-10-03.json", "复盘镜-4000-12-31.json",
    ]

    /// ★★ 不挡的话,「找回」永远拿 4000 年那份 —— 冻在最后一次按按钮的那一刻,
    ///   之后记的每一笔都不在里面。模拟器里旧版实测:「找到一份备份:复盘镜-4000-12-31.json」。
    func testAFileDatedInTheFutureIsNeverTheLatest() {
        XCTAssertEqual(BackupRotation.latest(among: Self.realFolder, now: at(2026, 10, 3, 15)),
                       "复盘镜-2026-10-03.json")
        XCTAssertNil(BackupRotation.latest(among: ["复盘镜-4000-12-31.json"], now: at(2026, 10, 3)))
    }

    /// ★ 余量:文件名按**设备时区**起。纽约晚上 10 点,人在上海的设备已经是明天 ——
    ///   那份是真的,必须认。
    func testTomorrowByTheDeviceClockStillCounts() {
        let names = ["复盘镜-2026-10-03.json", "复盘镜-2026-10-04.json"]
        XCTAssertEqual(BackupRotation.latest(among: names, now: at(2026, 10, 3, 22)),
                       "复盘镜-2026-10-04.json")
    }

    /// ★ 日期在未来的**不删、也不占名额** —— 和认不出日期的一个待遇:
    ///   删是不可逆的;让它占一个名额,就等于少留一天真的备份。
    func testAFutureFileIsNeitherDeletedNorTakesASlot() {
        let expired = BackupRotation.expired(among: Self.realFolder, keep: 10,
                                             now: at(2026, 10, 3, 15))
        XCTAssertFalse(expired.contains("复盘镜-4000-12-31.json"))
        // 16 份真日期留最新 10 份 ⇒ 删最老的 6 份,一份不多
        XCTAssertEqual(Set(expired), Set(Self.realFolder.prefix(6)))
    }

    // ── 今天要不要写 ────────────────────────────────────────────────

    func testFirstEverBackupIsNeeded() {
        XCTAssertTrue(BackupRotation.needsBackup(lastBackup: nil, now: at(2026, 9, 3)))
    }

    func testSameDayDoesNotBackupTwice() {
        XCTAssertFalse(BackupRotation.needsBackup(lastBackup: at(2026, 9, 3, 9),
                                                  now: at(2026, 9, 3, 15)))
    }

    func testNextDayNeedsANewBackup() {
        XCTAssertTrue(BackupRotation.needsBackup(lastBackup: at(2026, 9, 3, 15),
                                                 now: at(2026, 9, 4, 9)))
    }

    /// ★ 「今天」按**交易所时区**算。多伦多 21:00 和纽约 21:00 是同一天;
    ///   要是按设备时区判,跨时区旅行时会莫名其妙多备一份或少备一份。
    func testDayBoundaryFollowsTheExchangeTimeZone() {
        // 9/3 23:30 ET 和 9/4 00:30 ET 是**不同**的两天
        XCTAssertTrue(BackupRotation.needsBackup(lastBackup: at(2026, 9, 3, 23),
                                                 now: at(2026, 9, 4, 0)))
    }
}
