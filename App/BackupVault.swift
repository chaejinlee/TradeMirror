import Foundation

/// **每天自动备份到你选的文件夹**(iCloud Drive 里的文件夹就行),
/// 以及**重装之后把最新那份找回来**。
///
/// ★★ 先说清一条硬限制,免得期待落空:
///   <b>iOS 不允许 App 自己往 iCloud Drive 里写。</b>
///   要么申请 iCloud 容器权限(需要 $99 的开发者账号),
///   要么<b>由你亲手选一次文件夹</b> —— 选完系统给 App 一张
///   「security-scoped bookmark」,凭它以后可以**无需再问**地往那个文件夹写。
///   这条路不要钱,而且你选的文件夹可以就在 iCloud Drive 里
///   ⇒ 效果就是「每天自动备份到 iCloud」。
///
/// ★★ 重装之后为什么还要点一次:
///   删掉 App 时,沙盒**连同那张 bookmark 一起**被系统清掉了。
///   iOS 没有任何办法让 App 在没有你授权的情况下读到沙盒外的东西 ——
///   <b>这是系统的规矩,不是我偷懒。</b>
///   所以重装后是:**点一次「找回备份」→ 选回同一个文件夹 →
///   App 自动扫出最新的那份并告诉你是哪天、多少笔 → 一键恢复。**
@MainActor
final class BackupVault {

    static let shared = BackupVault()

    private let bookmarkKey = "backupFolderBookmark"
    private let lastBackupKey = "lastAutoBackupAt"
    private let lastErrorKey = "lastAutoBackupError"

    // MARK: - 文件夹

    /// 选好的备份文件夹。没选过就是 nil。
    private(set) var folder: URL?

    /// 上一次自动备份的时刻。
    var lastBackupAt: Date? {
        get { UserDefaults.standard.object(forKey: lastBackupKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastBackupKey) }
    }

    /// 上一次自动备份**失败的原因**(成功时清空)。
    ///
    /// ★★ 非存不可:自动备份是在后台悄悄跑的,失败**没有任何人在看**。
    ///   原来那句 `_ = backupIfNeeded(...)` 把返回值直接丢了 ——
    ///   于是「每天自动备份」可能已经好几天没成,而你以为它开着。
    var lastError: String? {
        get { UserDefaults.standard.string(forKey: lastErrorKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastErrorKey) }
    }

    var isConfigured: Bool { folder != nil }

    /// 这个功能现在到底是活的还是死的。判断逻辑在引擎里(有测试)。
    var health: BackupHealth {
        BackupHealth.of(isConfigured: isConfigured, lastBackup: lastBackupAt,
                        lastError: lastError)
    }

    private init() { folder = resolveBookmark() }

    /// 记住用户选的文件夹。★ 存 bookmark 而不是路径 ——
    /// iCloud Drive 的真实路径会变(容器 ID、同步搬迁),而 bookmark 跟着走。
    func remember(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData()
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        folder = url
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: lastBackupKey)
        UserDefaults.standard.removeObject(forKey: lastErrorKey)
        folder = nil
    }

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        else { return nil }
        // ★ bookmark 过期(文件夹被搬过)时**刷新**它,别默默失效。
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    // MARK: - 写

    enum VaultError: LocalizedError {
        case noFolder
        case unreachable
        /// ★★ 带上**系统给的原话**。2026-09-03 用户报「选好 iCloud 文件夹之后
        ///   没有显示备份文档」—— 而我这边只有一句笼统的「打不开」,
        ///   连我自己都查不出是权限、是没下载、还是别的。
        ///   <b>错的诊断和没有诊断一样难查</b>(这条今天已经说过一次)。
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFolder:    return Loc.t("还没有选备份文件夹")
            case .unreachable: return Loc.t("那个文件夹现在打不开(可能被删了、或者 iCloud 还没同步下来)")
            case .writeFailed(let why):
                return String(format: Loc.t("写不进那个文件夹:%@"), why)
            }
        }
    }

    /// 写一份今天的备份。**同一天重复调用会覆盖当天那份**,不会越堆越多。
    ///
    /// ★★ 这一层**不收 `now`**,时间一律取真的。
    ///   原来收一个 `now: Date = Date()`,「立刻备份一次」就拿 `.distantFuture` 冒充它
    ///   来绕过「今天写过了」—— 同一个 `now` 还被拿去起文件名、记「上次备份」,
    ///   写出了 `复盘镜-4000-12-31.json`(v3.7 起,2026-10-03 在用户的 iCloud 里抓到),
    ///   「上次自动备份」显示成不带年份的「12-31 19:00」,谁也看不出来。
    ///   按文件名挑最新,这份永远最新 ⇒ 重装后「找回」拿到的是一份冻住的旧数据。
    ///   ⇒ 想绕过「今天写过了」用 `force`;想冒充时间,编译都过不了。
    @discardableResult
    func writeBackup(data: Data) throws -> URL { try write(data: data, now: Date()) }

    private func write(data: Data, now: Date) throws -> URL {
        guard let folder else { throw VaultError.noFolder }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        // ★★ iCloud Drive 里的文件夹**可能还没下载到本地**,
        //   `fileExists` 会返回 false —— 而它明明是好的。
        //   原来那句 `guard fileExists else { throw .unreachable }`
        //   正是用户 2026-09-03「选好 iCloud 文件夹之后没有显示备份文档」的原因之一:
        //   <b>拿本地文件系统的判据去判一个云端位置。</b>
        //   ⇒ 先叫它下载,再直接写;写不进去由系统告诉我们为什么。
        try? FileManager.default.startDownloadingUbiquitousItem(at: folder)

        let dest = folder.appendingPathComponent(BackupRotation.fileName(for: now))

        // ★★ iCloud Drive 是 file provider 撑起来的位置,**写它必须走 NSFileCoordinator**。
        //   不协调的写入要么被拒、要么写完了不被 provider 认账 ——
        //   文件在「文件」App 里就是不出现。本地文件夹走这条路也一样对。
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing,
                                       error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) }
            catch { writeError = error }
        }
        if let e = coordError ?? (writeError as NSError?) {
            throw VaultError.writeFailed("\(e.localizedDescription) (\(e.domain) \(e.code))")
        }

        lastBackupAt = now
        pruneOldFiles(in: folder, now: now)
        return dest
    }

    /// 只在**今天还没备份过**时写。给「进前台 / 存完一笔」这类地方调。
    /// `force`:「立刻备份一次」—— 只跳过「今天写过没有」这一道,时间照样是真的。
    @discardableResult
    func backupIfNeeded(_ makeData: () -> Data?, force: Bool = false) -> Result<URL, Error>? {
        guard isConfigured else { return nil }
        let now = Date()
        guard force || BackupRotation.needsBackup(lastBackup: lastBackupAt, now: now)
        else { return nil }
        guard let d = makeData() else { return nil }
        do {
            let u = try write(data: d, now: now)
            lastError = nil                       // ★ 成功了就把旧的失败清掉
            return .success(u)
        } catch {
            // ★★ 把失败**记下来**。调用方可以不管返回值,但账不能不记 ——
            //   这正是 2026-09-05 复盘查出来的洞。
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    private func pruneOldFiles(in folder: URL, now: Date) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in BackupRotation.expired(among: names.filter { $0.hasSuffix(".json") }, now: now) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - 读回来

    /// iCloud 没下载的文件在目录里叫 `.复盘镜-2026-09-03.json.icloud` ——
    /// 还原成它真正的名字,否则「最新的一份」永远认不出来。
    static func materialisedName(_ n: String) -> String {
        guard n.hasPrefix("."), n.hasSuffix(".icloud") else { return n }
        return String(n.dropFirst().dropLast(".icloud".count))
    }

    struct Found {
        let url: URL
        let name: String
        let date: Date?
        let tradeCount: Int
    }

    /// 在某个文件夹里找**最新的一份**备份,并读出它有多少笔。
    ///
    /// ★ 读出笔数是为了让你在恢复之前就能判断「这份对不对」——
    ///   而不是恢复完才发现选错了文件夹。
    func findLatestBackup(in folder: URL) -> Found? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.startDownloadingUbiquitousItem(at: folder)
        // ★ iCloud 上还没下载下来的文件,文件名会带 `.` 前缀和 `.icloud` 后缀。
        //   直接列目录会漏掉它们 —— 那正是「明明有备份却说没找到」的原因。
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { Self.materialisedName($0) }
        guard let latest = BackupRotation.latest(among: names.filter { $0.hasSuffix(".json") })
        else { return nil }
        let url = folder.appendingPathComponent(latest)
        let count = (try? Importer.read(try Data(contentsOf: url)).trades.count) ?? 0
        return Found(url: url, name: latest,
                     date: BackupRotation.date(fromFileName: latest), tradeCount: count)
    }
}
