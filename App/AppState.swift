import Foundation
import Observation

@Observable
final class AppState {
    var trades: [Trade] = []
    /// 开仓前记下、还没对应到成交的计划。
    var plans: [PendingPlan] = []
    /// 每日收盘价簿。**填一次,当天该标的全部交易共用** —— 这是「越用越快」的机制。
    var closes = DailyCloseBook()
    /// 用户的硬规则(开仓前检查用)。
    var rules = TradingRules()
    /// 看过引导没有。★ 用 UserDefaults 而不是存档 —— 它是设备偏好,不是用户数据。
    var hasSeenGuide: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSeenGuide") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenGuide") }
    }
    /// 读盘出错时的横幅。★ 绝不静默 —— 竞品差评里「数据没了」的根源就是静默失败。
    var loadError: String?
    /// 上次用的标的,下次录入直接带出来(录入速度是 v1 一等公民)。
    var lastSymbol: String = "QQQ"
    /// ★★ **没记进来的那些**。看不见的漏记等于不存在 —— 见 `ImportLog.swift`。
    var importFailures: [ImportFailure] = []
    /// 月度对账:券商上做了几笔。
    var reconciliations: [Reconciliation] = []
    /// 纪律手册。★ 第一次用时种进去(见 `reload`)。
    var discipline = DisciplineBook()

    func saveDiscipline(_ b: DisciplineBook) { discipline = b; persist() }

    /// 记下一笔的纪律自检。
    func saveDisciplineCheck(_ c: DisciplineCheck?, for trade: Trade) {
        guard let c, !c.isEmpty else { return }     // 跳过 = 没答,什么都不写
        var t = trade; t.discipline = c; save(t)
    }

    /// 记一次导入失败。★ 立刻落盘 —— 这条记录的全部意义就是「别丢」。
    func noteImportFailure(_ reason: ImportFailure.Reason, lines: [String] = []) {
        importFailures.append(ImportFailure(reason: reason, lines: lines))
        persist()
    }

    /// 填/改某个月的券商笔数。
    func setBrokerCount(_ n: Int, month: String) {
        reconciliations.removeAll { $0.monthKey == month }
        if n > 0 { reconciliations.append(Reconciliation(monthKey: month, brokerTradeCount: n)) }
        persist()
    }

    private let store = TradeStore.default()
    let attachments = AttachmentStore.default()

    init() {
        reload()
        if DebugHooks.shouldSeedDemo, trades.isEmpty { save(DebugHooks.demoTrade()) }
    }

    func reload() {
        do { let a = try store.loadAll()
             trades = a.trades; plans = a.plans; closes = a.closes; rules = a.rules
             importFailures = a.failures; reconciliations = a.recons
             // ★ 第一次使用时把手册种进去。存档里有就用存档里的 ——
             //   用户改过的内容不许被种子覆盖。
             discipline = a.discipline ?? .seed
             loadError = nil }
        catch StoreError.unreadable(let backup) {
            trades = []; plans = []
            loadError = String(format: Loc.t(
                "数据文件读不出来。**原文件已留档**,没有被删除:\n%@"), backup)
        } catch StoreError.futureSchema(let f, let s) {
            trades = []; plans = []
            loadError = String(format: Loc.t(
                "这份数据是更新版本的 App 写的(v%1$@ > v%2$@)。请升级 App,不要在此版本继续记录,否则会丢字段。"),
                "\(f)", "\(s)")
        } catch {
            trades = []; plans = []
            loadError = String(format: Loc.t("读取失败:%@"), error.localizedDescription)
        }
    }

    func save(_ raw: Trade) {
        let t = attachPlanIfAny(raw)
        if let i = trades.firstIndex(where: { $0.id == t.id }) { trades[i] = t } else { trades.append(t) }
        lastSymbol = t.symbol
        persist()
    }

    func saveRules(_ r: TradingRules) { rules = r; persist() }

    /// 载入一笔示例交易。**只在用户主动点「看个例子」时调用** ——
    /// 竞品因为「删了还会自己回来」被打 1 星,所以这里绝不自动补。
    func loadSample() {
        guard !trades.contains(where: { $0.isSample }) else { return }
        var t = DebugHooks.sampleTrade()
        t.isSample = true
        trades.append(t); persist()
    }

    /// 今天已平仓的交易(纪律检查用)。
    var closedToday: [Trade] {
        let today = TradingDay.key(of: Date())
        return trades.filter { $0.isClosed && $0.tradingDayKey == today }
    }

    /// 记一条开仓前的计划。
    func addPlan(symbol: String, psychology: Psychology) {
        plans.append(PendingPlan(symbol: symbol, psychology: psychology)); persist()
    }
    /// 录入交易时自动接上事前的计划(接上就把计划消耗掉)。
    func attachPlanIfAny(_ t: Trade) -> Trade {
        guard t.psychology == nil, let p = PlanMatcher.find(for: t, in: plans) else { return t }
        var t2 = t; t2.psychology = p.psychology
        plans.removeAll { $0.id == p.id }
        return t2
    }

    /// 记下某天某标的的收盘价。返回受影响的交易数(用来告诉用户「填一次,N 笔都算得出来了」)。
    @discardableResult
    func setClose(_ price: Double?, for t: Trade) -> Int {
        closes.set(price, for: t); persist()
        guard let day = t.tradingDayKey else { return 0 }
        return closes.affectedTrades(trades, symbol: t.symbol, day: day).count
    }

    /// 批量保存(批量导入用)。
    func saveAll(_ ts: [Trade]) {
        for raw in ts {
            let t = attachPlanIfAny(raw)
            if let i = trades.firstIndex(where: { $0.id == t.id }) { trades[i] = t }
            else { trades.append(t) }
        }
        persist()
    }

    // ── 清理重复 ─────────────────────────────────────────────────────────
    // ★★ 2026-09-02 用户报「重新导入了,文件全部重复了」——
    //   我的导入脚本每次跑都生成新 UUID,而去重只看 id。已经从两头修:
    //   ① 脚本改成确定性 id ② 导入按**内容指纹**去重。
    //   但**已经重复了的数据得有办法清掉** —— 手动左滑删 10 笔不是办法,
    //   而且下次还可能因为别的原因重复。

    /// 找出重复(按内容指纹,不按 id)。
    var duplicates: [Deduper.Duplicate] { Deduper.find(in: trades) }

    /// 删掉重复里多出来的那些。**每组保留「填得最多」的那一笔** ——
    /// 用户可能已经在其中一份上补过收盘价/心理/原因,删错了就得白填一遍。
    @discardableResult
    func removeDuplicates() -> Int {
        let ids = Deduper.idsToDrop(in: trades)
        guard !ids.isEmpty else { return 0 }
        delete(ids)
        return ids.count
    }

    func delete(_ ids: Set<UUID>) {
        trades.removeAll { ids.contains($0.id) }
        persist()
        // 删交易时顺手清掉没人引用的图,否则磁盘会一直涨
        attachments.pruneOrphans(referencedBy: trades)
    }

    // ── 导出 / 备份 / 导回 ────────────────────────────────────────────────
    // ★ 一手数据:216 条竞品 1–2 星差评里「数据丢失」占 5%、「无法导出」占 2%。
    //   我们原本的形状和它一样 —— 全部压在沙盒一个文件里,且没有出口。

    /// 写到临时目录再交给系统分享单。**不落在 Documents**,避免用户下次看到一堆导出文件。
    private func temp(_ name: String, _ data: Data) -> URL? {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: u, options: .atomic); return u } catch {
            loadError = String(format: Loc.t("导出失败:%@"), error.localizedDescription)
            return nil
        }
    }

    func exportCSV() -> URL? {
        temp(Exporter.filename(ext: "csv"), Data(Exporter.csv(trades).utf8))
    }

    /// 备份文件的**字节**。★ 和手动导出走同一条路 ——
    /// 两条路意味着「自动备份出来的文件」和「手动导出的文件」可能不一样。
    func backupData() -> Data? {
        guard trades.contains(where: { !$0.isSample }) else { return nil }
        return try? Exporter.backup(trades: trades, plans: plans, closes: closes, rules: rules)
    }

    func exportBackup() -> URL? {
        guard let d = try? Exporter.backup(trades: trades, plans: plans,
                                           closes: closes, rules: rules) else {
            loadError = Loc.t("备份失败"); return nil
        }
        return temp(Exporter.filename(ext: "json"), d)
    }

    /// 从备份导回。**只合并,不覆盖** ——「Update reset my results」是竞品差评里最狠的一条。
    func importBackup(from url: URL) -> String {
        // 从「文件」App 选来的 URL 在沙盒外,必须先取用权限
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try Importer.read(try Data(contentsOf: url))
            let r = Importer.merge(file, into: trades)
            trades = r.trades
            // 规则/收盘价簿只在本地是空的时候才接受,免得覆盖用户当前的设置
            if let c = r.closes, closes.isEmpty { closes = c }
            if let rl = r.rules, rules == TradingRules() { rules = rl }
            persist()
            // ★ 这些是 Text(String) 的入参 —— 不显式查表就永远是中文
            var msg = String(format: Loc.t("导入 %lld 笔"), r.added)
            if r.skipped > 0 {
                msg += String(format: Loc.t(",跳过 %lld 笔(已经有了,没有替换)"), r.skipped)
            }
            if r.enrichedFields > 0 {
                msg += String(format: Loc.t("。另外给已有的 %1$lld 笔补上了 %2$lld 个空字段 —— **你自己填过的值一个都没动**。"),
                              r.enrichedTrades, r.enrichedFields)
            }
            return msg
        } catch Importer.Failure.notABackup {
            return Loc.t("这不是复盘镜的备份文件。你现有的数据没有被改动。")
        } catch Importer.Failure.futureSchema(let f, let s) {
            return String(format: Loc.t("这份备份来自更新的版本(v%1$lld > v%2$lld)。请先升级 App —— 现在导入会丢字段。"), f, s)
        } catch {
            return String(format: Loc.t("读不出来:%@。你现有的数据没有被改动。"), error.localizedDescription)
        }
    }

    func persist() {
        do { try store.save(trades, plans: plans, closes: closes, rules: rules,
                            failures: importFailures, recons: reconciliations,
                            discipline: discipline) }
        catch {
            loadError = String(format: Loc.t(
                "保存失败:%@。**请勿关闭 App**,先截图记录。"), error.localizedDescription)
        }
    }
}
