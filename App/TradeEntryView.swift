import SwiftUI
import PhotosUI

/// 录入页。**唯一的设计目标是快**(D1:不做券商同步,代价是手打,所以录入速度是一等公民)。
///
/// 2026-08-31 扩品种:股票/ETF(含做空)· 期权(13 种策略)· 期货(带点值)· 外汇。
/// 策略选完自动摆好腿,用户只填行权价和成交 —— 摆腿的逻辑在引擎的 `StrategyTemplate` 里,有测试。
struct TradeEntryView: View {
    @Environment(\.dismiss) private var dismiss

    enum AssetClass: String, CaseIterable, Identifiable {
        // i18n-ok:枚举原值(也是 LegKind 分类的 key),显示时走 LocalizedStringKey 翻
        case equity = "股票/ETF", option = "期权", futures = "期货", forex = "外汇"
        var id: String { rawValue }
    }

    struct FillRow: Identifiable {
        let id = UUID()
        var side: Side = .buy
        var time = Date()
        /// 这个时间是不是**用户/截图给的**。默认值一律 false。
        ///
        /// ★★ 用户 2026-09-03:「今天我添加的几笔全都是 11 点的时间点,但实际上不是」。
        ///   录入页的时间默认是「最近交易日 11:00」——<b>一个占位值</b>。
        ///   在不显示时间的年代它只影响排序;v3.2 开始显示时刻之后,
        ///   <b>这个占位值就变成了一条假记录</b>。
        ///   ⇒ 没确认过就**别当成事实**:存进 `Fill.timeIsEstimated`,显示层不显示时刻。
        var timeConfirmed = false
        var qty: String = "", price: String = "", underlying: String = ""
    }
    struct LegRow: Identifiable {
        let id = UUID()
        var right: OptionRight?          // nil = 正股腿
        var strikeText: String = ""
        var expiry: Date
        var hint: String
        var fills: [FillRow]
    }

    @State private var symbol: String
    @State private var assetClass: AssetClass = .option
    @State private var strategy: StrategyKind = .single
    @State private var futuresCode = "ES"
    @State private var forexSize: Double = 100_000
    @State private var defaultExpiry: Date
    @State private var legs: [LegRow] = []
    @State private var note = ""
    /// 编辑已有交易时保留原 id —— 否则保存会变成新增一笔(而不是改这一笔)。
    @State private var editingID: UUID? = nil
    /// 截图识别没认出来的字段名(界面上直接列出来)。
    @State private var parsedNotice: [String] = []
    /// 识别出来了但没把握的字段名(高亮提醒核对)。
    @State private var lowConfidence: [String] = []
    /// 贴上来的图表。★ 图在选中的那一刻就写盘了,所以取消录入会留下孤儿 ——
    /// 由 AppState 删交易时的 pruneOrphans 兜底。
    @State private var charts: [Attachment] = []
    @State private var chartItem: PhotosPickerItem?
    let attachmentStore = AttachmentStore.default()

    let onSave: (Trade) -> Void

    /// 从截图解析结果预填。**永不自动保存** —— 用户必须在这一页确认。
    /// 低置信度的字段由 `lowConfidence` 交给界面高亮。
    init(parsed p: ParsedTrade, fallbackSymbol: String, onSave: @escaping (Trade) -> Void) {
        self.onSave = onSave
        _symbol = State(initialValue: p.symbol?.value ?? fallbackSymbol)
        _editingID = State(initialValue: nil)
        _note = State(initialValue: "")
        _parsedNotice = State(initialValue: p.missing)
        _lowConfidence = State(initialValue: [
            p.symbol.map   { (Loc.t("标的"),   $0.confidence) },
            p.side.map     { (Loc.t("买/卖"),  $0.confidence) },
            p.quantity.map { (Loc.t("数量"),   $0.confidence) },
            p.price.map    { (Loc.t("成交价"), $0.confidence) },
            p.strike.map   { (Loc.t("行权价"), $0.confidence) },
            p.time.map     { (Loc.t("时间"),   $0.confidence) },
        ].compactMap { $0 }.filter { $0.1 < 0.75 }.map(\.0))

        let isOpt = p.right != nil
        _assetClass = State(initialValue: isOpt ? .option : .equity)
        _strategy = State(initialValue: .single)
        _futuresCode = State(initialValue: "ES")
        _forexSize = State(initialValue: 100_000)

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        func date(_ c: DateComponents?, fallback: Date) -> Date {
            guard var c else { return fallback }
            c.timeZone = TradingDay.exchangeTimeZone
            if c.year == nil  { c.year  = cal.component(.year,  from: fallback) }
            if c.month == nil { c.month = cal.component(.month, from: fallback) }
            if c.day == nil   { c.day   = cal.component(.day,   from: fallback) }
            return cal.date(from: c) ?? fallback
        }
        let base = Self.lastSessionMidday()
        let fillTime = date(p.time?.value, fallback: base)
        let exp = TradingDay.close(on: date(p.expiry?.value, fallback: fillTime))
        _defaultExpiry = State(initialValue: exp)

        let openSide = p.side?.value ?? .buy
        let qty = p.quantity.map { $0.value.cleanNum } ?? ""
        var rows = [FillRow(side: openSide, time: fillTime,
                            // 截图里认出了时间 ⇒ 那是券商给的事实,不是占位值
                            timeConfirmed: p.time?.value != nil,
                            qty: qty,
                            price: p.price.map { String(format: "%g", $0.value) } ?? "",
                            underlying: "")]   // ★ 标的价截图里通常没有,必须用户自己填
        // ★★ 仓位截图同时给了开仓均价和平仓均价 ⇒ 草稿直接给**两笔**成交。
        //   用户 2026-09-03:「理论上软件应该能自己计算出来」——
        //   两笔一摆,`realizedPnL` 就是现成的,不需要截图上印着盈亏。
        //   ⚠️ 平仓那一笔的**时刻截图里通常没有** ⇒ `timeConfirmed: false`,
        //     显示层会写 `--:--` 而不是编一个时间出来。
        if let x = p.exitPrice {
            rows.append(FillRow(side: openSide == .buy ? .sell : .buy, time: fillTime,
                                timeConfirmed: false,
                                qty: qty,
                                price: String(format: "%g", x.value),
                                underlying: ""))
        }
        _legs = State(initialValue: [LegRow(
            right: p.right?.value,
            strikeText: p.strike.map { $0.value.cleanNum } ?? "",
            expiry: exp,
            hint: isOpt ? Loc.t("单腿(从截图识别)") : Loc.t("股票/ETF(从截图识别)"),
            fills: rows)])
    }

    /// 编辑已有交易。**必须把 id 带上** —— 否则保存会新增一笔而不是改这一笔。
    ///
    /// ★ 这个入口是 2026-09-01 提审前自查补的:原来点一行只能看复盘,**没有编辑入口**,
    /// 录错一个数字只能删掉重录。审核员和用户都会立刻撞上这个洞。
    init(editing t: Trade, onSave: @escaping (Trade) -> Void) {
        self.onSave = onSave
        _symbol   = State(initialValue: t.symbol)
        _editingID = State(initialValue: t.id)
        _note     = State(initialValue: t.rawNoteAtEntry ?? "")
        _strategy = State(initialValue: t.strategy)

        // 品种由腿的类型反推(数据里的事实,不是另存一个可能不同步的字段)
        var ac: AssetClass = .equity
        var fcode = "ES", fsize = 100_000.0, exp = Self.lastSessionMidday()
        for leg in t.legs {
            switch leg.kind {
            case .option(_, _, let e): ac = .option; exp = e
            case .futures(let c, _, _): if ac == .equity { ac = .futures; fcode = c }
            case .forex(let sz):        if ac == .equity { ac = .forex; fsize = sz }
            case .equity: break
            }
        }
        _assetClass = State(initialValue: ac)
        _futuresCode = State(initialValue: fcode)
        _forexSize = State(initialValue: fsize)
        _defaultExpiry = State(initialValue: exp)

        _charts = State(initialValue: t.attachments)
        _legs = State(initialValue: t.legs.map { leg in
            var right: OptionRight? = nil
            var strike = "", legExp = exp
            if case .option(let r, let k, let e) = leg.kind { right = r; strike = k.cleanNum; legExp = e }
            return LegRow(right: right, strikeText: strike, expiry: legExp,
                          hint: leg.note ?? leg.kind.shortLabel,
                          fills: t.fills(of: leg).map { f in
                              FillRow(side: f.side, time: f.time,
                                      timeConfirmed: !f.timeIsEstimated,
                                      qty: f.quantity.cleanNum,
                                      price: String(format: "%g", f.price),
                                      // 0 = 合并截图时还没填的标的价,留空而不是显示 "0"
                                      underlying: (f.underlying).map { $0 > 0 ? String(format: "%g", $0) : "" } ?? "")
                          })
        })
    }

    init(symbol: String, onSave: @escaping (Trade) -> Void) {
        _symbol = State(initialValue: symbol)
        // ★ 时间默认到「最近一个交易日的盘中」而不是此刻 ——
        //   复盘天然是事后录入,默认「现在」几乎永远是错的(2026-08-31 实测出的最大摩擦)。
        let d = Self.lastSessionMidday()
        _defaultExpiry = State(initialValue: TradingDay.close(on: d))
        self.onSave = onSave
    }

    /// 录入时的默认时刻(交易所时区)。周末回退到上周五。
    ///
    /// ★ **盘中录入就用此刻** —— 边做边记时,「现在」几乎就是成交时刻。
    /// ★ 盘外(收盘后、开盘前、周末)回落到 11:00 —— 那是个明摆着的占位值。
    ///   无论哪一种,<b>没被用户碰过就都算「未确认」</b>(`timeConfirmed = false`),
    ///   显示层不会把它当成真实成交时刻。
    static func lastSessionMidday() -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        var d = Date()
        while TradingDay.isWeekend(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        var c = cal.dateComponents([.year, .month, .day], from: d)
        let now = cal.dateComponents([.hour, .minute], from: Date())
        let mins = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let inRTH = !TradingDay.isWeekend(Date()) && mins >= 9 * 60 + 30 && mins <= 16 * 60
        c.hour = inRTH ? now.hour : 11
        c.minute = inRTH ? now.minute : 0
        c.timeZone = TradingDay.exchangeTimeZone
        return cal.date(from: c) ?? d
    }

    // MARK: - 组装

    private func legKind(_ r: LegRow) -> LegKind? {
        switch assetClass {
        case .equity:  return .equity
        case .forex:   return .forex(contractSize: forexSize)
        case .futures: return FuturesContract.find(futuresCode)?.legKind
        case .option:
            guard let right = r.right else { return .equity }   // 备兑/领口里的正股腿
            guard let k = Double(r.strikeText), k > 0 else { return nil }
            return .option(right: right, strike: k, expiry: r.expiry)
        }
    }

    private var parsed: Trade? {
        guard !symbol.isEmpty, !legs.isEmpty else { return nil }
        var builtLegs: [Leg] = [], builtFills: [Fill] = []
        for r in legs {
            guard let kind = legKind(r) else { return nil }
            // i18n-ok:这是**比较**,不是显示 —— 拿模板原值当哨兵
            let leg = Leg(kind: kind, note: r.hint == "单腿" ? nil : r.hint)
            var got = false
            for f in r.fills {
                guard let q = Double(f.qty), q > 0,
                      let p = Double(f.price), p > 0 else { continue }
                // 标的价留空是允许的 —— 只影响「若在峰值出场」那一条
                builtFills.append(Fill(legID: leg.id, time: f.time, side: f.side,
                                       quantity: q, price: p, underlying: Double(f.underlying),
                                       timeIsEstimated: !f.timeConfirmed))
                got = true
            }
            guard got else { return nil }        // 每条腿至少要有一笔成交
            builtLegs.append(leg)
        }
        return Trade(id: editingID ?? UUID(),
                     symbol: symbol.uppercased(), strategy: assetClass == .option ? strategy : .single,
                     legs: builtLegs, fills: builtFills,
                     rawNoteAtEntry: note.isEmpty ? nil : note,
                     attachments: charts)
    }

    private func rebuildLegs() {
        guard assetClass == .option else {
            legs = [LegRow(right: nil, expiry: defaultExpiry, hint: assetClass.rawValue,
                           fills: [FillRow(time: Self.lastSessionMidday())])]
            return
        }
        legs = StrategyTemplate.drafts(for: strategy).map {
            LegRow(right: $0.right, expiry: defaultExpiry, hint: $0.hint,
                   fills: [FillRow(side: $0.suggestedSide, time: Self.lastSessionMidday())])
        }
    }

    // MARK: - 界面

    var body: some View {
        Form {
            if !parsedNotice.isEmpty || !lowConfidence.isEmpty {
                Section {
                    if !parsedNotice.isEmpty {
                        // ★ 字段名是引擎给的中文,插值进 LocalizedStringKey 是**不翻**的
                        //   ⇒ 逐项翻完再拼(和心理状态那串同一个规矩)。
                        Label("截图里没认出来,要你自己填:\(parsedNotice.localizedJoined)",
                              systemImage: "questionmark.circle.fill")
                        .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    if !lowConfidence.isEmpty {
                        Label("认出来了但没把握,请核对:\(lowConfidence.localizedJoined)",
                              systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    Label(md: "标的价可以不填。它只在**平仓那一笔**用得上(反解 IV 算峰值重定价),留空只少「若在峰值出场」一条。",
                          systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                } header: { Text("识别结果 · 请逐项确认后再保存") }
            }
            Section {
                TextField("标的(如 QQQ / TSLA / ES)", text: $symbol)
                    .textInputAutocapitalization(.characters)
                Picker("品种", selection: $assetClass) {
                    ForEach(AssetClass.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: assetClass) { _, _ in rebuildLegs() }

                switch assetClass {
                case .option:
                    Picker("策略", selection: $strategy) {
                        ForEach(StrategyKind.allCases) { Text($0.localizedName).tag($0) }
                    }
                    .onChange(of: strategy) { _, _ in rebuildLegs() }
                    DatePicker("到期日", selection: $defaultExpiry, displayedComponents: .date)
                        .onChange(of: defaultExpiry) { _, n in
                            for i in legs.indices where legs[i].right != nil {
                                legs[i].expiry = TradingDay.close(on: n)
                            }
                        }
                case .futures:
                    Picker("合约", selection: $futuresCode) {
                        ForEach(FuturesContract.all) { c in
                            Text("\(c.id) · \(c.name) · $\(c.pointValue.cleanNum)/点").tag(c.id)
                        }
                    }
                case .forex:
                    Picker("手数规格", selection: $forexSize) {
                        Text("标准手 100,000").tag(100_000.0)
                        Text("迷你手 10,000").tag(10_000.0)
                        Text("微型手 1,000").tag(1_000.0)
                    }
                case .equity:
                    Text("做空只要把第一笔成交选成「卖」—— 方向由成交决定,不用额外开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach($legs) { $leg in
                Section {
                    if assetClass == .option, leg.right != nil {
                        HStack {
                            Picker("", selection: Binding(
                                get: { leg.right ?? .call },
                                set: { leg.right = $0 })) {
                                Text("Call").tag(OptionRight.call); Text("Put").tag(OptionRight.put)
                            }.pickerStyle(.segmented).frame(width: 130)
                            TextField("行权价", text: $leg.strikeText).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        if strategy == .calendarSpread || strategy == .diagonalSpread {
                            DatePicker("这条腿的到期日", selection: $leg.expiry, displayedComponents: .date)
                        }
                    }
                    ForEach($leg.fills) { $f in FillRowEditor(row: $f, assetClass: assetClass) }
                        .onDelete { leg.fills.remove(atOffsets: $0) }
                    Button {
                        var n = FillRow(side: leg.fills.last?.side ?? .buy)
                        n.time = leg.fills.last?.time ?? Self.lastSessionMidday()
                        n.timeConfirmed = leg.fills.last?.timeConfirmed ?? false
                        n.underlying = leg.fills.last?.underlying ?? ""
                        leg.fills.append(n)
                    } label: { Label("加一笔成交", systemImage: "plus.circle.fill").font(.subheadline) }
                } header: {
                    Text(LocalizedStringKey(leg.hint))
                } footer: {
                    // ★ 时间没确认过就说清楚:那是默认值,不是成交时刻。
                    //   放在 section 脚注而不是每行 —— 每行都写一遍太吵。
                    if leg.fills.contains(where: { !$0.timeConfirmed }) {
                        Text(md: "⏰ 带 **?** 的时刻是**默认值**,不是成交时刻 —— 点一下时间选对,它才会被记成事实。不改也能存,但复盘页那里会显示 `--:--`。")
                    }
                }
            }

            if assetClass == .option, strategy == .custom {
                Section {
                    Button {
                        legs.append(LegRow(right: .call, expiry: defaultExpiry, hint: String(format: Loc.t("第 %lld 条腿"), legs.count + 1),
                                           fills: [FillRow(time: Self.lastSessionMidday())]))
                    } label: { Label("加一条腿", systemImage: "plus.square.on.square") }
                }
            }

            Section {
                TextField("可留空", text: $note, axis: .vertical).lineLimit(1...4)
            } header: { Text("开仓时你怎么想的(原话,别整理)") }

            Section {
                if !charts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(charts) { a in
                                ChartThumb(store: attachmentStore, attachment: a) {
                                    attachmentStore.delete(a)
                                    charts.removeAll { $0.id == a.id }
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                }
                PhotosPicker(selection: $chartItem, matching: .images) {
                    Label(charts.isEmpty ? "贴一张开仓时的图" : "再贴一张", systemImage: "chart.xyaxis.line")
                }
            } header: {
                Text("开仓时看到的图")
            } footer: {
                Text("TradingView / Webull 的图表没有成交明细,不做识别 —— 但它是你当时看到的东西。和上面的原话一样,复盘时最该回看的就是这两样。图只存在本机。")
            }
            .onChange(of: chartItem) { _, item in
                guard let item else { return }
                Task {
                    defer { chartItem = nil }
                    guard let d = try? await item.loadTransferable(type: Data.self) else { return }
                    if let a = try? attachmentStore.save(d, ext: "jpg") { charts.append(a) }
                }
            }

            if let t = parsed {
                // ★★ 体检放在**保存之前**。起因是用户第一份真实备份里
                //    strike 被填成了总金额(402 = 3×1.34×100),而我的测试一直是绿的。
                //    绿测试测的是我的转录,拦不住真实链路里的错 ——
                //    所以在数据本身上问一句「这可能吗」。
                let findings = Sanity.check(t)
                if !findings.isEmpty {
                    Section {
                        ForEach(findings) { f in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: f.level == .blocked
                                      ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(f.level == .blocked ? Theme.loss : Theme.warn)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: f.title).font(.subheadline.weight(.semibold))
                                    Text(md: f.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 2)
                        }
                    } header: {
                        Text("存之前先看一眼")
                    } footer: {
                        if findings.contains(where: { $0.level == .blocked }) {
                            Text(md: "红色那条是**算术上不可能**的,不是风格问题 —— 改对了才能存。")
                        }
                    }
                }
                AutoComputed(trade: t)
            }
        }
        .navigationTitle(editingID != nil ? "改这一笔"
                         : (parsedNotice.isEmpty && lowConfidence.isEmpty ? "记一笔" : "确认识别结果"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { if let t = parsed { onSave(t); dismiss() } }
                    // 「不可能」的数不给存。这不是替用户做判断 ——
                    // 权利金低于内在价值是无套利下界,和看法无关。
                    .disabled(parsed == nil || !(parsed.map { Sanity.blocking($0).isEmpty } ?? false))
            }
        }
        .onAppear { if legs.isEmpty && editingID == nil { rebuildLegs() } }
    }
}

/// 「不用你填」的部分 —— 凡是有唯一正确答案的,一律代码算(规范 §4)。
struct AutoComputed: View {
    let trade: Trade
    var body: some View {
        Section("自动算出(不用你填)") {
            LabeledContent("开仓均价", value: trade.averageEntry.f2)
            if trade.netDebit > 0 {
                LabeledContent("净借记(付出)") { Text(verbatim: Money.plain(trade.netDebit)).monospacedDigit() }
            } else if trade.netCredit > 0 {
                LabeledContent("净贷记(收入)") { Text(verbatim: Money.plain(trade.netCredit)).monospacedDigit() }
            }
            if let pnl = trade.displayablePnL {
                LabeledContent("盈亏") { Text(verbatim: Money.signed(pnl)).monospacedDigit() }
            } else {
                LabeledContent("状态") {
                    Text(verbatim: String(format: Loc.t("未平仓 · 在手 %1$@ %2$@"),
                                          trade.openQuantity.clean,
                                          trade.legs.first?.kind.localizedUnit ?? ""))
                }
            }
            if let mae = CounterfactualEngine.observedMAE(trade: trade) {
                LabeledContent("逆势加仓时已浮亏") {
                    Text("\(mae.pct.f1)%").foregroundStyle(Theme.loss)
                }
            }
            if trade.missingExitUnderlying {
                // ★ 原文写「其余三条照常算」—— 卡片数早就不是三条了(现在最多五条)。
                //   把具体数字写进文案,加一张卡就多一处过期。**只说关系,不说数量。**
                Label("平仓那一笔没填标的价 —— 只会少「若在峰值出场」那一条,其余照常算。",
                      systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if trade.hasWeekendFill {
                Label("有成交落在周末 —— 请检查日期", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warn).font(.footnote)
            }
        }
    }
}

struct FillRowEditor: View {
    @Binding var row: TradeEntryView.FillRow
    let assetClass: TradeEntryView.AssetClass

    private var priceLabel: LocalizedStringKey {
        switch assetClass {
        case .option:  return "权利金"
        case .futures: return "点数"
        case .forex:   return "汇率"
        case .equity:  return "价格"
        }
    }
    private var qtyLabel: LocalizedStringKey { assetClass == .equity ? "股数" : (assetClass == .forex ? "手数" : "张数") }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("", selection: $row.side) {
                    Text("买").tag(Side.buy); Text("卖").tag(Side.sell)
                }.pickerStyle(.segmented).frame(width: 96)
                // ★ 时间没被确认过时,**明着标出来** —— 那是个占位值,不是成交时刻。
                //   碰一下(改任何一位)就算确认。
                DatePicker("", selection: Binding(
                    get: { row.time },
                    set: { row.time = $0; row.timeConfirmed = true })).labelsHidden()
                Spacer(minLength: 4)
                if !row.timeConfirmed {
                    // ★ 只放一个图标 —— 文字徽章会把这一行挤出屏幕(实测)。
                    //   为什么要标:这个时刻是**默认值**,不是成交时刻。
                    Image(systemName: "clock.badge.questionmark")
                        .font(.footnote).foregroundStyle(Theme.warn)
                }
            }
            HStack(spacing: 8) {
                num($row.qty, qtyLabel)
                num($row.price, priceLabel)
                // ★ 线性品种的标的价 == 成交价,不问;期权只有平仓那一笔用得上,标成可留空。
                //   2026-09-01 实测反馈:「填数字好烦,每次都得去查」——
                //   查证后发现这个字段绝大多数情况根本用不到。
                if assetClass == .option { num($row.underlying, "标的价(可空)") }
            }
        }
        .padding(.vertical, 2)
    }

    /// ★ 占位符要能翻 —— 参数从 String 改成 LocalizedStringKey,
    ///   否则 TextField(String) 那一路又是永不本地化。
    private func num(_ b: Binding<String>, _ ph: LocalizedStringKey) -> some View {
        TextField(ph, text: b).keyboardType(.decimalPad).multilineTextAlignment(.center)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
