import SwiftUI
import UniformTypeIdentifiers

/// 数据与备份。
///
/// ★ 这一页不是「功能齐全」凑数用的。一手数据:216 条竞品 1–2 星差评里
///   「数据丢失/无备份」占 5%、「无法导出」占 2%,原话
///   「7 months of data was deleted. Just simply gone.」
///
/// 而我们把「删掉 App 就全没了」当隐私卖点写在商店描述里 ——
/// 站在用户那边读,同一句话也是**风险声明**。有出口,那句话才敢继续写。
struct DataView: View {
    /// 失败清单上的时间戳。★ 用**交易所时区**,和别处一致。
    static func stamp(_ d: Date) -> String {
        let c = TradingDay.day(of: d)
        return String(format: "%02d-%02d %@", c.month ?? 0, c.day ?? 0, TradingDay.clock(of: d))
    }

    @Environment(\.dismiss) private var dismiss
    let app: AppState

    @State private var csvURL: URL?
    @State private var backupURL: URL?
    /// ★★ 实测(2026-09-03):同一个视图上挂**三个** `.fileImporter`,
    ///   只有一个会真的弹出来 —— 点「选文件夹」什么都不发生。
    ///   ⇒ 收成**一个**,用这个枚举决定这次要选什么。
    enum PickMode: Identifiable { case backupFile, chooseFolder, restoreFolder
        var id: Int { hashValue } }
    @State private var pick: PickMode?
    /// ★★ **这次选的到底是什么** —— 单独存一份,和上面那个驱动弹窗的分开。
    ///
    ///   2026-09-03 用户报「选好 iCloud 文件夹之后没有显示备份文档」。
    ///   查下来:`isPresented` 那个 Binding 的 **setter 会在选择器关闭时先把 `pick` 置 nil**,
    ///   而完成回调是**之后**才跑的 —— 回调里读到的 `pick` 已经是 nil,
    ///   于是 `switch mode` 落进 `case nil: break`,<b>什么都不做,也不报错</b>。
    ///   用户看到的就是「选完了,啥也没发生」。
    ///
    ///   ⇒ 意图不能存在「同时被别人清空」的那个变量里。这一份只有我自己用完才清。
    @State private var pendingMode: PickMode?
    @State private var found: BackupVault.Found?
    @State private var vaultTick = 0            // 选完文件夹要刷新这一段
    /// ★ 备份出错的话就**写在备份那一段里**,不要丢到页面最底下。
    @State private var vaultError: String?
    /// 刚写成功的那个文件名 —— 让用户当场看见「东西确实出去了」。
    @State private var lastWritten: String?
    /// ★ 换语言要让整棵树重建,否则已经渲染好的 Text 不会重新查译文。
    @AppStorage(Loc.storeKey) private var lang = AppLanguage.system.rawValue
    @AppStorage("autoFetchCandles") private var autoFetchCandles = true
    @State private var result: String?

    private var realCount: Int { app.trades.filter { !$0.isSample }.count }

    private var vault: BackupVault { BackupVault.shared }

    /// 自动备份那一段。★ 单拎出来:`body` 一大,SwiftUI 的类型检查预算就爆
    ///   —— 这个文件为这事栽过一次。
    @ViewBuilder private var autoBackupSection: some View {
        Section {
            if let e = vaultError {
                Label {
                    // 错误原文已经是本地化过的 —— 再包一层 key 只会查不到
                    Text(verbatim: e)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote).foregroundStyle(Theme.warn)
            }
            if let f = lastWritten {
                Label {
                    Text(verbatim: f)
                } icon: {
                    Image(systemName: "checkmark.icloud.fill").foregroundStyle(Theme.profit)
                }
                .font(.footnote)
            }
            if vault.isConfigured {
                LabeledContent("上次自动备份") {
                    Text(verbatim: vault.lastBackupAt.map(Self.stamp) ?? Loc.t("还没备过"))
                        .foregroundStyle(vault.lastBackupAt == nil ? Theme.warn : .secondary)
                }
                Button {
                    vaultError = nil; lastWritten = nil
                    switch vault.backupIfNeeded({ app.backupData() }, force: true) {
                    case .success(let u): lastWritten = u.lastPathComponent
                    case .failure(let e): vaultError = e.localizedDescription
                    case nil:             vaultError = Loc.t("还没有可导出的交易")
                    }
                    vaultTick += 1
                } label: { Label("立刻备份一次", systemImage: "arrow.clockwise.icloud") }
                Button(role: .destructive) {
                    vault.forget(); vaultTick += 1
                } label: { Label("不再自动备份", systemImage: "xmark.icloud") }
            } else {
                Button {
                    pick = .chooseFolder; pendingMode = .chooseFolder
                } label: { Label("选一个文件夹,以后每天自动备份", systemImage: "icloud.and.arrow.up") }
            }
            Button {
                pick = .restoreFolder; pendingMode = .restoreFolder
            } label: { Label("重装之后:从备份文件夹找回", systemImage: "clock.arrow.circlepath") }
        } header: {
            Text("自动备份")
        } footer: {
            // ★ 原来三句话,删到一句:剩下两句(小云朵、$99 容器)是「为什么」,不是「怎么用」。
            Text(md: vault.isConfigured
                 ? Loc.t("每天第一次打开时写一份,最多留 30 天。选在 iCloud Drive 里就等于备份到 iCloud。")
                 : Loc.t("选一次文件夹(放在 iCloud Drive 里最好),之后每天自动写、不再问你。"))
        }
        .id(vaultTick)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if realCount == 0 {
                        // 0 笔还给导出,只会得到一个空文件 —— 那不是「有功能」,是浪费一次点击
                        Label("还没有可导出的交易", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else if let u = backupURL {
                        ShareLink(item: u) {
                            Label("导出备份文件", systemImage: "arrow.up.doc.fill")
                        }
                    } else {
                        Label("导出备份文件", systemImage: "arrow.up.doc.fill")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        pick = .backupFile; pendingMode = .backupFile
                    } label: {
                        Label("从备份导回", systemImage: "arrow.down.doc")
                    }
                } header: {
                    Text("备份")
                } footer: {
                    // ★★ 2026-09-24:原来是三段话,最后一段教人「在电脑上跑
                    //   `tools/moomoo_enrich.py`」—— <b>那是写给开发者的操作说明</b>,
                    //   对一个不写代码的用户没有任何可操作性。只留他真正需要知道的那一句。
                    Text(md: "导回时**只补不覆盖** —— 你填过的值一个都不会动。")
                }

                // ★★ 每天自动备份到你选的文件夹(可以就在 iCloud Drive 里)。
                //   为什么要你亲手选一次:iOS 不允许 App 自己往沙盒外写 ——
                //   要么买 $99 申请 iCloud 容器,要么由你授权一个文件夹。
                //   选完系统给一张 bookmark,之后**每天自动写,不再问你**。
                autoBackupSection

                Section {
                    if let u = csvURL, realCount > 0 {
                        ShareLink(item: u) {
                            Label("导出 CSV", systemImage: "tablecells")
                        }
                    } else {
                        Label("导出 CSV", systemImage: "tablecells").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("给 Excel / 表格看")
                } footer: {
                    Text(md: "一行 = **一笔成交**(不是一笔交易),所以加仓、分批平仓、多条腿都留得住;想按交易汇总,对 `trade_id` 做透视即可。\n\n**说清楚:CSV 是有损的,导不回来。** 要留退路请用上面的备份文件。")
                }

                // ★ 有重复才出现。没重复时不该占一行位置说「没有重复」。
                if !app.duplicates.isEmpty {
                    Section {
                        ForEach(app.duplicates) { d in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(d.keep.symbol) "
                                     + (d.keep.legs.first?.kind.shortLabel ?? ""))
                                    .font(.subheadline.weight(.medium))
                                Text(verbatim: String(
                                    format: Loc.t("%1$lld 份完全一样的记录 · %2$@"),
                                    d.drop.count + 1, d.keep.tradingDayKey ?? ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            let n = app.removeDuplicates()
                            result = n > 0 ? String(format: Loc.t("删掉了 %lld 笔重复的。"), n)
                                             : Loc.t("没有重复。")
                            refresh()
                        } label: {
                            Label("清理重复(保留填得最多的那份)",
                                  systemImage: "square.on.square.badge.person.crop")
                        }
                    } header: {
                        Text("发现重复")
                    } footer: {
                        Text(md: "同一笔交易被存了多份 —— **标的、合约、每一笔成交完全相同**。\n清理时每组**保留填得最多的那一份**(收盘价、心理、原因、路径都算),其余删掉。\n\n★ 起因是导入脚本每次生成新 id、而去重只看 id。现在两头都修了:脚本 id 固定,导入也按**内容**去重 —— 再导不会重复。")
                    }
                }

                // ★★ 没记进来的那些。看不见的漏记等于不存在 —— 所以要看得见。
                if !app.importFailures.isEmpty {
                    Section {
                        ForEach(app.importFailures.sorted { $0.at > $1.at }.prefix(12)) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(f.reason.localizedLabel)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(verbatim: Self.stamp(f.at))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if !f.lines.isEmpty {
                                    Text(verbatim: f.lines.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            app.importFailures = []; app.persist(); refresh()
                        } label: { Label("清空这个清单", systemImage: "trash") }
                    } header: {
                        Text("没记进来的(\(app.importFailures.count))")
                    } footer: {
                        Text(md: "★ 这些是**导进来但没成的**截图。留着它们是因为:漏掉的**不是随机样本** —— 亏损单更烦、更不想记,统计会因此偏乐观。\n历史页顶上的「对账」能算出这个月到底差几笔。")
                    }
                }

                Section {
                    Toggle(isOn: $autoFetchCandles) {
                        Text("打开复盘页自动补当天 K 线")
                    }
                } header: {
                    Text("联网")
                } footer: {
                    Text(md: "开着的话,打开一笔的复盘页时会去取**那天的分钟 K 线**,发出去的只有**代码和日期**。\n关掉之后只有你点「自动填标的价」才联网 —— 计算全在本机,任何时候都不上传你的交易。")
                }

                Section {
                    Picker("语言", selection: $lang) {
                        ForEach(AppLanguage.allCases) { l in
                            Text(verbatim: l.label).tag(l.rawValue)
                        }
                    }
                } header: {
                    Text("语言")
                } footer: {
                    Text(md: "改了立刻生效,不用重开 App。\n★ 还没翻到的句子会**显示中文**,不会显示成空白或占位符 —— 宁可是中文,也不要一个假的英文。")
                }

                Section {
                    LabeledContent("交易") {
                        Text(verbatim: String(format: Loc.t("%lld 笔"), realCount))
                    }
                    LabeledContent("存放位置") { Text("本机沙盒") }
                } footer: {
                    Text(md: Loc.t("数据只在这台设备上,**从不上传**。iPhone 的整机备份会带上它,所以**换手机不会丢**;但**误删 App 会**。这就是上面那两个按钮存在的原因。")
                        + (app.trades.contains { $0.isSample }
                           ? Loc.t("\n\n示例那笔**不会**进导出 —— 备份是你的数据,不该混进我编的那笔。") : ""))
                }

                if let r = result {
                    Section { Text(verbatim: r).font(.footnote) }
                }
            }
            .navigationTitle("数据与备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            } }
            .fileImporter(isPresented: Binding(get: { pick != nil },
                                               set: { if !$0 { pick = nil } }),
                          allowedContentTypes: pick == .backupFile ? [.json] : [.folder],
                          allowsMultipleSelection: false) { out in
                let mode = pendingMode          // ★ 不读 `pick`:它这时候已经被清掉了
                pendingMode = nil
                switch out {
                case .success(let urls):
                    if let u = urls.first { handlePick(mode, u) }
                case .failure(let e):
                    vaultError = String(format: Loc.t("没能打开这个文件:%@"),
                                        e.localizedDescription)
                }
                pick = nil
            }
            .task { refresh() }
        }
        // ★★ 实测(2026-09-03):`.fileImporter` 和 `.confirmationDialog` 挂在**同一个视图**上时,
        //   两个都不弹 —— 连原本好用的「从备份导回」都一起哑了。
        //   SwiftUI 的呈现修饰符互相排斥,得挂在**不同层**上。
        //   <b>这一条只有在模拟器里点一下才会发现</b>,编译和测试全都是绿的。
        .confirmationDialog("找到一份备份", isPresented: Binding(
            get: { found != nil }, set: { if !$0 { found = nil } }),
            titleVisibility: .visible) {
            if let f = found {
                Button("恢复这一份") {
                    result = app.importBackup(from: f.url); found = nil; refresh()
                }
                Button("取消", role: .cancel) { found = nil }
            }
        } message: {
            if let f = found {
                Text(md: String(format: Loc.t("%1$@ · %2$lld 笔\n恢复时**只补不覆盖**:你现在已有的记录一条都不会被改。"),
                                f.name, f.tradeCount))
            }
        }
    }

    /// 选完之后干什么。★ 三条路各自的后续都在这一处 ——
    /// 分散在三个 importer 里就是三份要各自维护的接线。
    private func handlePick(_ mode: PickMode?, _ u: URL) {
        switch mode {
        case .backupFile:
            result = app.importBackup(from: u); refresh()
        case .chooseFolder:
            vaultError = nil; lastWritten = nil
            do {
                try vault.remember(u)
                // 选完立刻写一份 —— 让用户当场看到文件,而不是「明天再说」
                if let d = app.backupData() {
                    lastWritten = try vault.writeBackup(data: d).lastPathComponent
                } else {
                    vaultError = Loc.t("还没有可导出的交易")
                }
            } catch { vaultError = error.localizedDescription }
            vaultTick += 1
        case .restoreFolder:
            try? vault.remember(u)              // 顺手把自动备份也接上
            found = vault.findLatestBackup(in: u)
            if found == nil { result = Loc.t("这个文件夹里没有找到备份文件") }
            vaultTick += 1
        case nil:
            // ★ 真到了这里就是接线坏了。**说出来** —— 默默 break 正是这次的病因。
            vaultError = Loc.t("选完了却没接上(内部状态丢了)—— 请再试一次")
        }
    }

    private func refresh() {
        csvURL = app.exportCSV()
        backupURL = app.exportBackup()
    }
}
