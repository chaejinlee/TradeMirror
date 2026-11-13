import SwiftUI
import PhotosUI

struct TradeListView: View {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase
    /// ★ 三个 `.sheet` 挂在同一个视图上会互相打架(2026-09-01 实测:点行没反应)。
    ///   SwiftUI 的正确写法是**一个 sheet + 一个枚举**。
    enum Sheet: Identifiable {
        case new, review(Trade), edit(Trade), fromShot(ParsedTrade), history
        case plan, psychology(Trade), batch([BatchImporter.Draft], ImportTally), guide, data
        case distribution, rules, reconcile, kelly
        case openPlan(Trade)
        case discipline(Trade)
        case disciplineBook
        var id: String {
            switch self {
            case .new:            return "new"
            case .review(let t):  return "r-\(t.id)"
            case .edit(let t):    return "e-\(t.id)"
            case .fromShot:       return "shot"
            case .history:        return "history"
            case .plan:           return "plan"
            case .psychology(let t): return "psy-\(t.id)"
            case .batch:          return "batch"
            case .guide:          return "guide"
            case .distribution:   return "distribution"
            case .rules:          return "rules"
            case .reconcile:      return "reconcile"
            case .kelly:          return "kelly"
            case .data:           return "data"
            case .openPlan(let t): return "op-\(t.id)"
            case .discipline(let t): return "dis-\(t.id)"
            case .disciplineBook: return "disbook"
            }
        }
    }
    @State private var sheet: Sheet?
    /// 批量导入时还没问到的那几笔 —— 一笔一笔问,问完一个弹下一个。
    @State private var reasonQueue: [Trade] = []
    /// 一张平仓截图,但库里没有对应的开仓 —— 先问用户,别默默记成空头。
    @State private var orphanClose: ParsedTrade?
    /// 热力图里点开的那一格。
    @State private var pickedDay: HeatmapCell?
    /// ★ 和 ScoreboardView 共用同一把 key —— 两处各存各的,
    ///   就会出现「上面显示月、点开却按天筛」。
    @AppStorage("scoreboardPeriod") private var scoreboardPeriodRaw = StatsPeriod.day.rawValue
    /// 从截图进录入页之后,到底存了没有。
    @State private var shotSaved = false
    @State private var importedLineCount = 0
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var ocrBusy = false
    /// OCR 一个字都没认出来时的提示。**不静默失败。**
    @State private var ocrFailed = false
    /// 识别出来后发现能并进已有交易时,先问一句 —— **不替用户决定**。
    @State private var pendingMerge: (parsed: ParsedTrade, match: TradeMatcher.Match)?
    @State private var askMerge = false
    /// 并进去之后还有剩量时的提示。★ 用户要求「直到全部 sell 完成」——
    /// 那就得让他知道**还剩多少**,否则他不知道要不要再截一张。
    @State private var mergeNote: String?

    /// 列表用的排序(最新在前)。★ 抽出来是因为同一条排序表达式在 body 里出现两次,
    /// 把 SwiftUI 的类型检查预算耗光 —— 报错却是「无法在合理时间内完成类型检查」。
    private var sortedTrades: [Trade] {
        app.trades.sorted {
            ($0.fills.first?.time ?? .distantPast) > ($1.fills.first?.time ?? .distantPast)
        }
    }

    // ★ body 拆开:SwiftUI 的类型检查是**按整个表达式**算预算的。
    //   这个 body 长到编译器直接报「无法在合理时间内完成类型检查」,
    //   而且报的行会跳来跳去(先是 onDelete,修完又变成一句 Text)——
    //   那是在提示「整体太大」,不是那一行有问题。逐行改是打地鼠,拆开才是修。
    @ViewBuilder private var plansSection: some View {
        if !app.plans.isEmpty {
            Section {
                ForEach(app.plans) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: p.symbol).font(.subheadline.weight(.semibold))
                            if p.psychology.hasRedFlag {
                                Image(systemName: "flame.fill").foregroundStyle(Theme.warn).font(.caption)
                            }
                            Spacer()
                            Text("信心 \(p.psychology.confidence)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: p.psychology.states.localizedJoined)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    idx.map { app.plans[$0].id }.forEach { id in app.plans.removeAll { $0.id == id } }
                }
            } header: {
                Text("开仓前记下的(录入对应交易时会自动接上)")
            }
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let err = app.loadError {
            Section {
                // ★★ 这条消息是运行时拼出来的,里面带 markdown 星号。
                //   原来用 `Text(verbatim:)` ⇒ <b>星号原样显示</b>(实测截图里就是 `**原文件已留档**`)。
                //   `Text(md:)` 吃 String:本地化查不到就原样返回,再走 markdown 解析 —— 正好。
                Label { Text(md: err) }
                      icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(Theme.warn).font(.footnote)
            }
        }
    }

    /// 备份**已经死了**的时候挂一条 —— 挂在**主页**,不是藏在数据页里。
    ///
    /// ★★ 原来失败唯一的痕迹是数据页上「上次备份」那个日期不往前走,
    ///   而那一页是你**已经起疑**才会去看的。
    ///   备份这个功能的全部意义就是「不用惦记」,所以它坏了必须自己出声。
    /// ★ 只在真出事时出现 —— 常驻的提示等于没有提示。
    @ViewBuilder private var backupBanner: some View {
        let h = BackupVault.shared.health
        if h.isAlarming, let msg = h.message({ Loc.t($0) }) {
            Section {
                Button { sheet = .data } label: {
                    Label { Text(verbatim: msg) }
                          icon: { Image(systemName: "externaldrive.badge.exclamationmark") }
                        .foregroundStyle(Theme.warn).font(.footnote)
                }
            }
        }
    }

    /// 今天已平仓的那些 —— 熔断器要看它。
    private var closedToday: [Trade] {
        let key = TradingDay.key(of: Date())
        return app.trades.filter {
            !$0.isSample && $0.isClosed
                && ($0.fills.map(\.time).max().map { TradingDay.key(of: $0) } == key)
        }
    }

    /// **熔断器的常驻横幅。**
    ///
    /// ★★ 2026-09-22 复盘查出来的洞:`RuleEngine.check` 全项目只有一个调用点 ——
    ///   「开仓前」那一屏。而用户 23 笔已平仓里只有 6 笔填过心理状态,
    ///   <b>也就是说这个熔断器四次里最多被问到一次</b>。
    ///   09-04 亏 $893、09-08 亏 $796 —— 正是日亏上限存在的理由,
    ///   <b>而它当时根本没有机会说话</b>。
    /// ★ 全过就不出声 —— 常驻的绿色提示等于没有提示。
    @ViewBuilder private var rulesBanner: some View {
        let st = RuleEngine.status(app.rules, .init(closedToday: closedToday))
        if st.shouldShow {
            Section {
                Button { sheet = .rules } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(st.hits) { RuleRow(v: $0) }
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Label(st.worst == .blocked ? "今天该停手了" : "今天要留神",
                      systemImage: st.worst == .blocked ? "xmark.octagon.fill"
                                                        : "exclamationmark.triangle.fill")
                    .foregroundStyle(st.worst == .blocked ? Theme.loss : Theme.warn)
            }
        }
    }

    /// **对账提醒** —— 唯一能打破「拿 App 自己的输出验 App」的东西。
    /// ★ 只问已经过完的月份,一次只问一个,填过就不再问。
    @ViewBuilder private var reconcileBanner: some View {
        if let ask = ReconciliationPrompt.next(trades: app.trades,
                                               records: app.reconciliations) {
            Section {
                Button { sheet = .reconcile } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: String(format: Loc.t("对一下 %@ 的账"), ask.monthKey))
                                .font(.subheadline)
                            Text(verbatim: String(format: Loc.t("App 里记了 %lld 笔 —— 券商月结单上是几笔?"),
                                                  ask.recorded))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "checklist").foregroundStyle(.blue) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if app.trades.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有交易").font(.headline)
                    Text(md: "在券商成交详情页截图,**分享 → 复盘镜**;或者点右上角的图片按钮从相册选(可多选)。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    Button { sheet = .guide } label: {
                        Label("先看个例子", systemImage: "sparkles").font(.subheadline)
                    }
                    // ★ 空列表正是「我的数据没了」那一刻看到的画面 ——
                    //   恢复入口必须**摆在这里**,而不是藏在菜单第二层。
                    Button { sheet = .data } label: {
                        Label("从备份导回", systemImage: "arrow.down.doc").font(.subheadline)
                    }
                    Text("计算全在本机,不连券商、不注册账号。")
                        .font(.caption).foregroundStyle(.tertiary)
                }.padding(.vertical, 6)
            }
        }
    }

    /// ★★ 2026-09-24 美化:原来是 25 行一模一样的行,**每行都重复完整日期**,
    ///   看不出哪天赚哪天亏,也看不出一天做了几笔。
    ///   ⇒ 按天分组,组头写日期 + 当天合计;归日规则和热力图同一条(`DayGroups`)。
    @ViewBuilder private var tradeRows: some View {
        ForEach(DayGroups.group(app.trades)) { g in
            Section {
                ForEach(g.trades) { t in
                    // ★ `.buttonStyle(.plain)` 只把**文字本身**算作命中区域,中间的 Spacer 是空的
                    //   —— 2026-09-01 实测:点行中间毫无反应,点 "QQQ" 才有。
                    //   `.contentShape(Rectangle())` 把整行都变成可点区域。
                    Button { sheet = .review(t) } label: {
                        TradeRow(trade: t, dayKey: g.key).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { sheet = .edit(t) } label: { Label("改", systemImage: "pencil") }
                            .tint(.blue)
                    }
                }
                .onDelete { idx in app.delete(Set(idx.map { g.trades[$0].id })) }
            } header: {
                DayHeader(group: g)
            }
        }
    }

    // ★ 从 body 里搬出来:9 个 case 的 switch 让 SwiftUI 的类型检查预算爆掉。
    //   报错的行会一路跳(onDelete → 一句 Text → ForEach → 这里),
    //   那是「整体太大」的信号,不是某一行有毛病 —— 逐行改是打地鼠。
    @ViewBuilder private func sheetContent(_ which: Sheet) -> some View {
        switch which {
        case .new:
            // 记完直接进复盘页 —— 反事实才是产品价值,不该让用户再点一次才看得到。
            TradeEntryView(symbol: app.lastSymbol) { t in
                app.save(t); afterSave(t)
            }
        case .data:
            DataView(app: app)
        case .discipline(let t):
            // ★ 跳过也要往下走 —— 否则跳过一次就再也到不了复盘页
            DisciplineCheckView(trade: t, book: app.discipline) { check in
                app.saveDisciplineCheck(check, for: t)
                Task { @MainActor in go(ImportFlow.afterDiscipline(t), t) }
            }
        case .disciplineBook:
            DisciplineBookView(book: app.discipline) { app.saveDiscipline($0) }
        case .openPlan(let t):
            // ★ 跳过也要往下走 —— 否则批量导入里跳过一笔,后面几笔就再也问不到了。
            OpenPlanView(trade: t) { filled in
                if let filled { app.save(filled) }
                afterReasons(filled ?? t)
            }
        case .guide:
            OnboardingView { app.loadSample() }
        case .rules:
            RulesView(rules: app.rules, closedToday: closedToday) { app.saveRules($0) }
        case .reconcile:
            // ★ 只问**已经过完**的那个月 —— 当月的月结单还没出
            ReconcilePromptView(ask: ReconciliationPrompt.next(trades: app.trades,
                                                               records: app.reconciliations)) {
                app.setBrokerCount($0, month: $1)
            }
        case .kelly:
            // ★ 用户 2026-10-04:「做进 app 里,我可以随时修改预算来计算对应仓位」
            KellyView(trades: app.trades)
        case .distribution:
            // ★ 点某一格直接进那笔的复盘页 —— 图看出「哪一笔不对劲」之后
            //   下一步一定是「那到底是哪一笔」,不该逼人回列表里翻。
            DistributionView(trades: app.trades) { t in
                Task { @MainActor in go(.review, t) }
            }
        case .history:
            HistoryView(trades: app.trades, failures: app.importFailures,
                        recons: app.reconciliations, discipline: app.discipline,
                        onSetBrokerCount: { n, m in app.setBrokerCount(n, month: m) })
        case .plan:
            PsychologyView(beforeOutcome: true, initialSymbol: app.lastSymbol,
                           rules: app.rules, closedToday: app.closedToday,
                           onSaveRules: { app.saveRules($0) }) { sym, psy in
                app.addPlan(symbol: sym, psychology: psy)
            }
        case .psychology(let t):
            PsychologyView(beforeOutcome: false, initialSymbol: t.symbol,
                           existing: t.psychology) { _, psy in
                var x = t; x.psychology = psy; app.save(x)
            }
        case .review(let t):
            ReviewView(trade: t,
                       onEdit: { sheet = .edit(t) },
                       onPersist: { app.save($0) },
                       onRecordPsychology: { sheet = .psychology(t) },
                       onRecordDiscipline: { sheet = .discipline(t) },
                       sharedClose: app.closes.close(for: t),
                       trailingStopPct: app.rules.trailingStopPct,
                       onSetClose: { app.setClose($0, for: t) })
        case .batch(let drafts, let tally):
            BatchImportView(drafts: drafts, tally: tally) { ds in
                // ★★ 这里以前只 saveAll 就结束了 —— 一笔进来就是平的,
                //   于是**从来没人问过原因**(用户 2026-09-03 报的那条)。
                // ★★ `compactMap` 会把**建不出交易的那几组静默丢掉** ——
                //   全丢光时就是「点了保存,什么都没发生」。和上面同一个形状。
                let built = ds.map { (d: $0, t: buildTrade($0)) }
                let saved = built.compactMap(\.t)
                app.saveAll(saved)
                let lost = built.count - saved.count
                if lost > 0 {
                    for _ in 0..<lost { app.noteImportFailure(.unusable) }
                    mergeNote = String(format: Loc.t(
                        "有 %1$lld 组建不成交易,没有保存(另外 %2$lld 组存好了)。\n★ 多半是缺了标的或成交价 —— 回去单张重新导。"),
                        lost, saved.count)
                }
                let ask = saved.filter { ImportFlow.needsReasons($0) }
                if let first = ask.first {
                    reasonQueue = Array(ask.dropFirst())
                    go(.askReasons, first)
                } else if lost == 0, !saved.isEmpty {
                    // ★★ 2026-09-23 用户:「记录不进去」。
                    //   实情是**进去了**,只是并进了一笔 8 月的未平仓位:
                    //   净量没变、日期没变、还是「未平仓」、没有盈亏 ——
                    //   <b>屏幕上前后一模一样,他当然以为没进去。</b>
                    //   ⇒ 没有后续页面要弹时,**必须自己说一句存到哪了**。
                    let merged = saved.filter { !$0.isClosed }
                    mergeNote = merged.isEmpty
                        ? String(format: Loc.t("存好了 %lld 笔。"), saved.count)
                        : String(format: Loc.t(
                            "存好了 %1$lld 笔。其中 %2$@ 还没平完 —— 它按**开仓日**排在列表里,不在最上面。"),
                            saved.count, merged.map(\.symbol).joined(separator: "、"))
                }
            }
        case .fromShot(let p):
            // ★★ 从截图进来却没保存 = 「嫌烦不记了」。这正是选择偏差的来源之一,
            //   所以它也算一次**没记进来**,要留痕。
            TradeEntryView(parsed: p, fallbackSymbol: app.lastSymbol) { t in
                shotSaved = true; app.save(t); afterSave(t)
            }
            .onAppear { shotSaved = false }
            .onDisappear { if !shotSaved { app.noteImportFailure(.abandoned) } }
        case .edit(let t):
            TradeEntryView(editing: t) { updated in
                app.save(updated)          // id 不变 ⇒ 覆盖而不是新增
                sheet = .review(updated)   // 「改」是回头修数,不该再问一遍计划
            }
        }
    }

    var body: some View {
        List {
            // ★★ 2026-09-02 用户要求:主页要有日/周/月/年战绩。
            //   放在最上面,但**刻意做得紧凑** —— 它是「记账」那一半,
            //   不该把「反事实」那一半(交易列表 → 复盘页)挤下去。
            Section {
                ScoreboardView(trades: app.trades) { cell in pickedDay = cell }
            }
            plansSection
            errorBanner
            // ★ 顺序 = 紧急程度:该停手 > 备份坏了 > 该对账了
            rulesBanner
            backupBanner
            reconcileBanner
            emptyState
            tradeRows
            // ★ 版本戳:重装后一眼能看出新旧。
            //   之前版本号写死 0.1,用户重装完根本无法判断装没装上。
            Section {
                Text(verbatim: BuildInfo.stamp)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.clear)
        }
        // ★★ 每天第一次打开(以及每次回到前台)就写一份备份。
        //   `backupIfNeeded` 自己判「今天写过没有」,所以这里可以放心地反复调。
        //   ⚠️ 失败**不弹窗打断** —— 但会记在数据页的「上次自动备份」上,
        //     一眼能看出它已经好几天没成了。
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            _ = BackupVault.shared.backupIfNeeded { app.backupData() }
        }
        // ★ 单独一个 sheet:和 `$sheet` 那个共用会变成「谁先谁后」的竞态。
        .sheet(item: $pickedDay) { cell in
            // ★ 必须把周期一起传下去 —— 点开某个月却按天筛,会拿回一个空清单
            DayDetailView(cell: cell, trades: app.trades,
                          period: StatsPeriod(rawValue: scoreboardPeriodRaw) ?? .day) { t in
                // 关掉这一层再开复盘页 —— 同一帧里换两个 sheet 会被吞掉
                Task { @MainActor in sheet = .review(t) }
            }
        }
        .navigationTitle("复盘")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // ★ 合成一个菜单,而不是再加一个按钮 ——
                //   iPhone 顶栏塞到第 6 个图标就开始互相挤,谁都点不准。
                Menu {
                    Button { sheet = .guide } label: {
                        Label("这是什么", systemImage: "questionmark.circle")
                    }
                    Button { sheet = .disciplineBook } label: {
                        Label("纪律手册", systemImage: "list.bullet.clipboard")
                    }
                    Button { sheet = .distribution } label: {
                        Label("盈亏分布", systemImage: "chart.bar.xaxis")
                    }
                    .disabled(app.trades.isEmpty)
                    Button { sheet = .kelly } label: {
                        Label("凯利仓位", systemImage: "scalemass")
                    }
                    .disabled(app.trades.isEmpty)
                    Button { sheet = .rules } label: {
                        Label("交易规则", systemImage: "shield.lefthalf.filled")
                    }
                    Button { sheet = .data } label: {
                        Label("数据与备份", systemImage: "externaldrive")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { sheet = .history } label: {
                    Label("历史分析", systemImage: "chart.bar.doc.horizontal")
                }
                .disabled(app.trades.isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                // ★ 心理状态必须**事前**记 —— 事后补的会被结果污染。
                Button { sheet = .plan } label: { Label("开仓前", systemImage: "brain.head.profile") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .new } label: { Label("记一笔", systemImage: "plus") }
            }
            ToolbarItem(placement: .primaryAction) {
                // PhotosPicker 不需要相册权限(系统选择器只把选中的那张交给 App)
                // ⇒ 隐私标签不用改,仍是「不收集数据」。
                // ★ 不要用 .screenshots 筛选:券商截图可能是别人发来的、AirDrop 的、或整理过的,
                //   那些在系统里都不算「截屏」。实测选择器直接显示「无照片」。
                // ★ 多选:一笔交易两张截图,一天 5 笔就是 10 张 —— 一次全选进来。
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                    if ocrBusy { ProgressView() }
                    else { Label("从截图", systemImage: "photo.badge.plus") }
                }
                .disabled(ocrBusy)
            }
        }
        // ★ 从别的 App「分享 → TradeMirror」进来的图。
        //   走这条而不是 Share Extension:扩展要与主 App 共享数据就必须 App Group,
        //   而 App Group 是**付费开发者项目**才有的能力(2026-09-01 查证)。
        //   声明 CFBundleDocumentTypes 是免费账号也能用的路子。
        .onAppear {
            // ★ 只在**从没看过**时自动弹一次。看过就不再打扰。
            if !app.hasSeenGuide {
                app.hasSeenGuide = true
                sheet = .guide
            }
        }
        .onOpenURL { url in
            ocrBusy = true
            Task {
                defer { ocrBusy = false }
                // 「就地打开」的文件要先申请安全作用域,否则读不到
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data) else {
                    app.noteImportFailure(.ocrEmpty); ocrFailed = true; return
                }
                let lines = await ScreenshotOCR.recognize(img)
                // ★★ 这里以前只是弹一句「没认出文字」就完了 —— 不计数、不留痕。
                //   而 2026-09-03 那张失败的恰好是**亏损单**:漏掉的不是随机样本。
                guard !lines.isEmpty else {
                    app.noteImportFailure(.ocrEmpty); ocrFailed = true; return
                }
                let p = ScreenshotParser.parse(lines: lines)
                route(p)
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            ocrBusy = true
            Task {
                defer { ocrBusy = false; photoItems = [] }
                var parsed: [ParsedTrade] = []
                // ★★ 一次导入的**账**:选了几张,少的那几张各去了哪。
                //   2026-09-04 用户选 8 张、3 张丢了价,而确认页写的是「来自 5 张截图」——
                //   <b>「8」这个数从来没到过那一屏</b>,差额只有他自己发现。
                //   下面这三个 `continue` 每一个都在把一张图变没,现在每一个都留痕。
                var tally = ImportTally(selected: items.count)
                for item in items {
                    // ★ 每张图**恰好**走一次 `outcome` + 一次 `record` ——
                    //   分支判据在引擎里(有测试),这里只负责执行。
                    let img = (try? await item.loadTransferable(type: Data.self))
                        .flatMap { UIImage(data: $0) }
                    let lines = img == nil ? [] : await ScreenshotOCR.recognize(img!)
                    let p = lines.isEmpty ? nil : ScreenshotParser.parse(lines: lines)
                    let o = ImportTally.outcome(imageLoaded: img != nil, lines: lines, parsed: p)
                    tally.record(o)
                    switch o {
                    case .accepted:   parsed.append(p!)
                    case .unusable:   app.noteImportFailure(.unusable, lines: lines)
                    case .ocrEmpty, .unreadable: app.noteImportFailure(.ocrEmpty, lines: lines)
                    }
                }
                guard !parsed.isEmpty else { ocrFailed = true; return }
                importedLineCount = parsed.count
                if parsed.count == 1 {
                    // 单张走原来的确认页(能逐字段核对)
                    let p = parsed[0]
                    route(p)
                } else {
                    // 多张 → 自动配对 → 一次确认。★ 仍然不自动保存。
                    sheet = .batch(BatchImporter.group(parsed, existing: app.trades), tally)
                }
            }
        }
        // ★★ 2026-09-02 查出来的重大缺口:`askMerge` 这个开关从 v1.0 起就有,
        //    **但从来没有任何界面挂在它上面** —— 也就是说,
        //    截图明明匹配上了未平仓的同一张期权,App 把开关一打、然后**什么都没发生**,
        //    那张图就无声无息地消失了。
        //    而 commit ce7c9ab 的信息写的是「导入时询问是否并进已有仓位」。
        //    ⇒ 我提交了一个**什么都不做**的功能,并且在提交信息里说它能用。
        //    ⇒ 引擎侧(TradeMatcher)一直有测试并且是对的;**接线这一层从来没测过**。
        .confirmationDialog("这张图是同一笔的另一半?",
                            isPresented: $askMerge, titleVisibility: .visible) {
            if let m = pendingMerge {
                Button("并进那笔(\(m.match.trade.symbol))") { doMerge(m.parsed, m.match) }
                Button("新建一笔") { sheet = .fromShot(m.parsed); pendingMerge = nil }
                Button("取消", role: .cancel) { pendingMerge = nil }
            }
        } message: {
            if let m = pendingMerge { Text(verbatim: m.match.reason) }
        }
        // ★ 标题改中性:这条现在不只报「还没平完」,也报「存好了 N 笔」和合并失败的原因。
        //   ★ 用 `Text(md:)` 不是 `Text(verbatim:)` —— 消息里带 markdown,
        //     verbatim 会把星号原样打出来(这个项目栽过 10 次的那一类)。
        .alert("导入", isPresented: Binding(
            get: { mergeNote != nil }, set: { if !$0 { mergeNote = nil } })) {
            Button("好") { mergeNote = nil }
        } message: {
            if let n = mergeNote { Text(md: n) }
        }
        // ★★ 截图上写着「Sell to close」,而库里没有对应的开仓 ——
        //   把这个矛盾说出来,而不是默默记成一个空头。
        .confirmationDialog("这是一张平仓截图,但没找到对应的开仓",
                            isPresented: Binding(get: { orphanClose != nil },
                                                 set: { if !$0 { orphanClose = nil } }),
                            titleVisibility: .visible) {
            if let p = orphanClose {
                Button("先去导入开仓那张") { orphanClose = nil }
                Button("就记这一笔(当成新开的仓位)") {
                    sheet = .fromShot(p); orphanClose = nil
                }
                Button("取消", role: .cancel) { orphanClose = nil }
            }
        } message: {
            Text(md: "截图上写着「**Sell to close / 平仓**」,但这边没有这张合约的未平仓记录。\n\n把**开仓那张**也导进来,两张会并成一笔 —— 到时候盈亏是**算出来的**,不需要截图上印着金额。\n\n要是现在就记,它会被当成**新开的空头仓位**。")
        }
        .alert("这张图没认出文字", isPresented: $ocrFailed) {
            Button("好") { }
        } message: {
            Text("换一张清晰点的截图,或者直接手动记一笔。识别全在本机做,没有联网。")
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                sheetContent(which)
            }
        }
    }
}

extension TradeListView {

    /// 存完之后往哪走。
    ///
    /// ★★ 未平仓 → **立刻问计划**(为什么开、止损止盈在哪);已平仓 → 进复盘页。
    ///   为什么不都进复盘页:未平仓的交易在复盘页**一条反事实都算不出**,
    ///   进去只会看到一堆空格。而「为什么开这单」这个问题**只有现在问才算事前**——
    ///   等到平仓后再问,填的是「我事后觉得当时的理由」(规范 [C5])。
    /// ★★ 2026-09-03 用户报:「完整的一笔完成的订单 ≥2 张截图放入软件之后
    ///   **不能填写交易入场以及出场原因**」。
    ///   旧实现是 `t.isClosed ? .review : .openPlan` —— <b>已平仓的直接跳去复盘页,
    ///   而复盘页没有填原因的地方</b>,所以那两个字段永远只能靠改单去补。
    ///   ⇒ 只要**还缺原因**,先问;问完(或跳过)再进复盘。
    func afterSave(_ t: Trade) { go(ImportFlow.next(after: t, book: app.discipline), t) }

    /// 填完原因(或跳过)之后往哪走。★ 用 `Task` 推到下一个 runloop ——
    ///   同一帧里既 dismiss 又换 sheet,SwiftUI 会把新的那个吞掉。
    func afterReasons(_ t: Trade) {
        if let next = reasonQueue.first {              // 批量导入:接着问下一笔
            reasonQueue.removeFirst()
            Task { @MainActor in sheet = .openPlan(next) }
        } else {
            go(ImportFlow.afterReasons(t, book: app.discipline), t)
        }
    }

    /// 换页面。**判断在 `ImportFlow`(有测试),这里只负责照做。**
    ///
    /// ★★ 必须推到下一个 runloop。`TradeEntryView` 的保存按钮是
    ///   `onSave(t); dismiss()` —— <b>`dismiss()` 会把 sheet 绑定置 nil,
    ///   把我们刚刚赋的新值盖掉</b>,于是保存完什么都不弹。
    ///   这是 2026-09-03 在模拟器里实测发现的:代码注释写着「记完直接进复盘页」,
    ///   而实际上从「记一笔」这条路进来**一次都没弹出来过**。
    ///   ⇒ 又是「注释描述意图、代码没做到」那一类。
    private func go(_ step: ImportFlow.Step, _ t: Trade) {
        Task { @MainActor in
            switch step {
            case .askReasons:    sheet = .openPlan(t)
            case .askDiscipline: sheet = .discipline(t)
            case .review:        sheet = .review(t)
            case .none:          sheet = nil
            }
        }
    }

    /// 一张截图解析完之后往哪走。**两条导入路径共用这一处** ——
    /// 分别写两遍就是下一个「同一个病换了个入口」。
    @MainActor
    func route(_ p: ParsedTrade) {
        if let m = TradeMatcher.find(for: p, in: app.trades) {
            pendingMerge = (p, m); askMerge = true
            return
        }
        // ★★ 2026-09-03 用户报的那条:一张「Sell to close」在没有对应开仓记录时,
        //   会被当成**开了一个空头** —— 于是既不是平仓、也没有盈亏。
        //   而截图上券商<b>明明白白写着 “Sell to close”</b>。
        //   ⇒ 不猜、也不硬并:把这个矛盾**说给用户听**,让他决定。
        if p.intent?.value == .close {
            orphanClose = p
            return
        }
        sheet = .fromShot(p)     // ★ 仍然进确认页,不自动保存
    }

    /// 把这张截图并进已有的那一笔。**时间以那笔自己的开仓日为基准**,
    /// 券商截图常常只给「10:13 am」而没有日期 —— 用「最近交易日」补会把卖单
    /// 盖到别的日子上,甚至排到买入之前。
    func doMerge(_ p: ParsedTrade, _ m: TradeMatcher.Match) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        let base = m.trade.fills.map(\.time).min() ?? Date()
        var when = base
        if var c = p.time?.value {
            c.timeZone = TradingDay.exchangeTimeZone
            if c.year == nil  { c.year  = cal.component(.year,  from: base) }
            if c.month == nil { c.month = cal.component(.month, from: base) }
            if c.day == nil   { c.day   = cal.component(.day,   from: base) }
            when = cal.date(from: c) ?? base
        }
        guard let merged = TradeMatcher.appendFill(p, to: m.trade, leg: m.leg,
                                                   underlying: nil, at: when)
        else {
            // ★★ 这里原来是**静默 return** —— 弹窗一关,什么都不发生、没有错误、不留痕迹。
            //   用户看到的就是<b>「放进去没反应」</b>,而这正是本项目反复栽的那一类。
            //   (2026-09-05 的 `guard let px … else { continue }`、
            //    2026-09-02 那个「什么都不做的 askMerge 开关」,同一个形状。)
            //   ⇒ 并不进去就说为什么,并且**留痕**。
            pendingMerge = nil
            app.noteImportFailure(.unusable)
            mergeNote = String(format: Loc.t(
                "并不进去:这张是「%1$@ %2$@」,而那笔 %3$@ 上没有能对上的未平量。\n★ 它没有被保存 —— 用「新建一笔」把它单独记下来。"),
                p.side?.value == .buy ? Loc.t("买") : Loc.t("卖"),
                (p.quantity?.value ?? 0).cleanNum, m.trade.symbol)
            return
        }
        app.save(merged)
        pendingMerge = nil
        // 平完了就直接进复盘页(反事实这时才算得出);还有剩量就留在列表上
        // ★ 并完就平了 ⇒ 先问「为什么走」,再进复盘。直接跳复盘就又没人问了。
        if merged.isClosed { go(ImportFlow.next(after: merged), merged) }
        else { mergeNote = String(
            format: Loc.t("已并进去。这条腿还剩 %1$@ %2$@未平 —— 卖完再截一张图。"),
            abs(merged.netQuantity(of: m.leg)).cleanNum, m.leg.kind.localizedUnit) }
    }

    /// 把一组解析结果拼成一笔交易。缺关键字段的成交直接跳过,**不编数**。
    func buildTrade(_ d: BatchImporter.Draft) -> Trade? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        func when(_ p: ParsedTrade, base: Date) -> Date {
            guard var c = p.time?.value else { return base }
            c.timeZone = TradingDay.exchangeTimeZone
            if c.year == nil  { c.year  = cal.component(.year,  from: base) }
            if c.month == nil { c.month = cal.component(.month, from: base) }
            if c.day == nil   { c.day   = cal.component(.day,   from: base) }
            return cal.date(from: c) ?? base
        }
        let base = TradeEntryView.lastSessionMidday()

        if var t = d.mergeInto {
            // ★★ 2026-09-02 用户报的「识别添加的期权时间对不上」就在这两行:
            //   ① 原来并进 `t.legs.first` —— 多腿时会并到**错的腿**上。
            //      要并进**真正匹配上的那条**(还有未平量、合约对得上的那条)。
            //   ② 原来用 `base = lastSessionMidday()` 补日期。券商截图常常只给
            //      「10:13 am」而没有日期,于是这一笔被盖上**最近一个交易日**的戳,
            //      而不是**它要并进去的那笔交易自己的日期** ——
            //      买在 8/6、卖被记成 9/1,甚至可能排到买入**之前**。
            guard let leg = t.legs.first(where: { abs(t.netQuantity(of: $0)) > 1e-9 })
                    ?? t.legs.first else { return nil }
            // 并进已有交易时,以**那笔自己的开仓日**为基准补日期
            let mergeBase = t.fills.map(\.time).min() ?? base
            for p in d.parts {
                // ★★ 这里原来是 `else { continue }` —— **静默跳过一笔没读出价的成交**。
                //   后果不是「少一个数字」:张数对不上 ⇒ 这笔永远平不了 ⇒
                //   未平仓不给盈亏 ⇒ <b>它从此不进胜率、不进热力图、不进任何统计</b>。
                //   2026-09-04 那笔亏损就是这样从历史里消失的,而且不留痕迹。
                //   ⇒ 现在整笔**失败**(返回 nil)。确认页已经先一步挡住了,
                //     走到这里说明前面漏了,那就宁可存不进去,也不要存个残的。
                guard let q = p.quantity?.value, let px = p.price?.value,
                      let side = p.side?.value else { return nil }
                t.fills.append(Fill(legID: leg.id, time: when(p, base: mergeBase),
                                    side: side, quantity: q, price: px,
                                    // 截图里没认出时间 ⇒ 用的是补出来的,别当事实
                                    timeIsEstimated: p.time?.value == nil))
            }
            return t
        }

        guard let head = d.parts.first, let sym = head.symbol?.value else { return nil }
        let kind: LegKind
        if let r = head.right?.value, let k = head.strike?.value {
            var e = head.expiry?.value ?? DateComponents()
            e.timeZone = TradingDay.exchangeTimeZone
            if e.year == nil { e.year = cal.component(.year, from: base) }
            let ex = TradingDay.close(on: cal.date(from: e) ?? base)
            kind = .option(right: r, strike: k, expiry: ex)
        } else { kind = .equity }

        let leg = Leg(kind: kind)
        var fills: [Fill] = []
        for p in d.parts {
            // ★★ 这里原来是 `else { continue }` —— **静默跳过一笔没读出价的成交**。
            //   后果不是「少一个数字」:张数对不上 ⇒ 这笔永远平不了 ⇒
            //   未平仓不给盈亏 ⇒ <b>它从此不进胜率、不进热力图、不进任何统计</b>。
            //   2026-09-04 那笔亏损就是这样从历史里消失的,而且不留痕迹。
            //   ⇒ 现在整笔**失败**(返回 nil)。确认页已经先一步挡住了,
            //     走到这里说明前面漏了,那就宁可存不进去,也不要存个残的。
            guard let q = p.quantity?.value, let px = p.price?.value,
                  let side = p.side?.value else { return nil }
            fills.append(Fill(legID: leg.id, time: when(p, base: base),
                              side: side, quantity: q, price: px,
                              timeIsEstimated: p.time?.value == nil))
            // ★ 仓位截图给了平仓均价 ⇒ 补上平仓那一笔,盈亏自己就算得出来
            if let x = p.exitPrice?.value {
                fills.append(Fill(legID: leg.id, time: when(p, base: base),
                                  side: side == .buy ? .sell : .buy, quantity: q, price: x,
                                  timeIsEstimated: true))
            }
        }
        guard !fills.isEmpty else { return nil }
        return Trade(symbol: sym, strategy: .single, legs: [leg], fills: fills)
    }
}

struct TradeRow: View {
    let trade: Trade
    /// 这一行所在分组的日子。★ 开仓日和它不同时(隔夜单)要把开仓日也写出来,
    ///   否则「15:20 → 10:18」看起来像是倒着走的时间。
    var dayKey: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            // 左边一条细色条:扫一眼就知道这一天红绿各几笔
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 3.5)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: trade.symbol).font(.headline)
                    // ★ 两个都是运行时 String(策略 rawValue 是存档值,
                    //   shortLabel 来自引擎)—— `Text(String)` 不本地化,必须包 key。
                    Text(LocalizedStringKey(
                        trade.isMultiLeg ? trade.strategy.rawValue
                                         : (trade.primaryLeg?.kind.shortLabel ?? "")))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    if trade.isMultiLeg {
                        Text("\(trade.legs.count) 腿").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !trade.addsWhileUnderwater.isEmpty {
                        Pill(text: Loc.t("逆势加仓"), tint: Theme.warn)
                    }
                    if trade.isSample {
                        Pill(text: Loc.t("示例"), tint: .secondary)
                    }
                }
                // ★ 用户 2026-09-03:「订单里面没显示具体开单时间」。
                //   ⚠️ 时刻按**交易所时区** —— 和归日、分桶用的是同一个时区。
                //   ★ 日期已经在组头里了,这里只留时刻(隔夜单例外,见 `dayKey`)。
                Text(verbatim: timeLine)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let pnl = trade.displayablePnL {
                // ★ 用户 2026-09-03:「添加每笔订单盈利百分比」。
                //   分母是**净借记**(真金白银付出去的钱);贷记开仓拿不到分母 ⇒ 不显示。
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: Money.signed(pnl))
                        .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.pnl(pnl))
                    if let r = trade.returnOnDebit {
                        Text(verbatim: Money.pct(r))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.pnl(pnl).opacity(0.85))
                    }
                }
            } else {
                // ★ 未平仓不显示盈亏 —— 持仓成本不是亏损
                VStack(alignment: .trailing, spacing: 2) {
                    Text("未平仓").font(.caption.weight(.semibold)).foregroundStyle(Theme.open)
                    Text("持 \(trade.openQuantity.clean) \(trade.legs.first?.kind.localizedUnit ?? "张")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var accent: Color {
        guard let p = trade.displayablePnL else { return Theme.open.opacity(0.6) }
        return Theme.pnl(p)
    }

    private var timeLine: String {
        let entry = trade.entryClock ?? "--:--"
        // 隔夜单:开仓日不是分组那天 ⇒ 把开仓日写上
        let openKey = trade.tradingDayKey
        let prefix: String = {
            guard let d = dayKey, let o = openKey, o != d else { return "" }
            return Self.shortDate(o) + " "
        }()
        return prefix + entry + (trade.exitClock.map { "  →  " + $0 } ?? "") + holding + openingAmount
    }

    /// ★ 用户 2026-10-06:「增加持仓时间功能」。开平仓时间有一边是估的(或旧版占位)就不写 —— 不给假时长。
    private var holding: String {
        guard let s = trade.holdingSeconds else { return "" }
        return "  ·  " + HoldingTime.format(s, Loc.t)
    }

    /// ★ 用户 2026-10-05:「添加每笔的开仓金额」。复盘页的头卡里早有「成本」,列表里一直没有。
    ///   借记开仓 = 真金白银付出去的钱;贷记开仓(先收钱:卖 put、卖价差)写「收」—— 那不是本金。
    private var openingAmount: String {
        if trade.netDebit > 0.005 {
            return "  ·  " + String(format: Loc.t("开仓 %@"), Money.plain(trade.netDebit))
        }
        if trade.netCredit > 0.005 {
            return "  ·  " + String(format: Loc.t("开仓收 %@"), Money.plain(trade.netCredit))
        }
        return ""
    }

    /// `2026-09-22` → `9/22`。
    static func shortDate(_ key: String) -> String {
        let p = key.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return key }
        return "\(m)/\(d)"
    }
}

/// 一天的组头:`9月3日 周四` ······ `4 笔 · +$934`。
struct DayHeader: View {
    let group: DayGroups.Group

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if group.closedCount > 0 {
                Text(verbatim: String(format: Loc.t("%lld 笔"), group.closedCount))
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: Money.signed(group.realized))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.pnl(group.realized))
            } else if group.openCount > 0 {
                Text("未平仓").font(.caption.weight(.medium)).foregroundStyle(Theme.open)
            }
        }
        .textCase(nil)
        .padding(.top, 4)
    }

    /// `今天` / `昨天` / `9月3日 周四`。
    private var title: String {
        let today = TradingDay.key(of: Date())
        let yest = TradingDay.key(of: Date().addingTimeInterval(-86_400))
        if group.key == today { return Loc.t("今天") }
        if group.key == yest { return Loc.t("昨天") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = TradingDay.exchangeTimeZone
        f.locale = Loc.locale        // ★ 跟着 App 里选的语言走,不是系统语言
        f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return f.string(from: group.date)
    }
}
