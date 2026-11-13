import SwiftUI

/// 反事实表 —— 产品的核心页。
///
/// 排序刻意不按「最刺激」排,按**可执行性**排(规范 §3.1):
/// 「峰值」是事后视角、永远达不到,单独放主位会把 App 变成后悔生成器。
/// 主位给「持有到收盘」(对 0DTE 最要命且完全可执行),「卖早了」放最后并常驻提醒。
struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let trade: Trade
    /// 点「改」时回调。为 nil 时不显示按钮(例如 DEBUG 演示页)。
    var onEdit: (() -> Void)? = nil
    /// ★ 把用户填的峰值/收盘价**存回 Trade** ——
    /// 之前它们只是 @State,关掉页面就没了,导致跨笔汇总根本做不了。
    var onPersist: ((Trade) -> Void)? = nil
    /// 没记心理状态时,提供补记入口(会被标记为事后补的)。
    var onRecordPsychology: (() -> Void)? = nil
    /// 纪律自检的补记入口。★ 没有它的话,「跳过」就等于**永久放弃** ——
    ///   而这张表要攒够样本才有用,少一笔就少一笔。
    var onRecordDiscipline: (() -> Void)? = nil
    /// 当天该标的的公共收盘价(填一次全天共用)。
    var sharedClose: Double? = nil
    /// 移动止损反事实用的回撤百分比。**取用户自己规则里的数,不由我挑。**
    var trailingStopPct: Double = 25
    /// 保存收盘价到当天价簿,返回受影响的交易数。
    var onSetClose: ((Double?) -> Int)? = nil
    @State private var affected = 0

    @State private var peakText: String
    @State private var closeText: String
    @State private var peakTime: Date
    @State private var usePeakTime = false
    /// 自动取价的状态。★ 唯一联网处,失败也不许挡住手填。
    @State private var fetching = false
    @State private var fetchNote: String?
    /// 每条期权腿「收盘时的真实价」。key = leg.id
    @State private var closePxText: [UUID: String] = [:]
    /// 刚抓回来的分钟 K。★ 和 `closePxText` 同一个理由:
    /// 存下去了但当前这张页面还拿着旧快照,不放进 `liveTrade` 的话
    /// **用户会看到「已抓到 1209 根」却仍是示意图**。
    @State private var fetchedPaths: [UUID: [PriceBar]] = [:]
    @State private var fetchedUnderlying: [PriceBar]?
    /// 打开页面自动补当天 K 线。默认开;数据页可关。
    @AppStorage("autoFetchCandles") private var autoFetchCandles = true
    /// 这次打开已经试过了 —— 失败不重试,别让每次滚动都打一遍网络。
    @State private var triedAutoFetch = false
    /// 自动取 K 线失败的原因。★ 取不到要说,不能只是不画。
    @State private var candleFailure: String?
    /// 请求是被**取消**的(视图换掉了),不是失败 ⇒ 下次进来重试。
    @State private var candleWasCancelled = false

    init(trade: Trade, onEdit: (() -> Void)? = nil, onPersist: ((Trade) -> Void)? = nil,
         onRecordPsychology: (() -> Void)? = nil,
         onRecordDiscipline: (() -> Void)? = nil,
         sharedClose: Double? = nil, trailingStopPct: Double = 25,
         onSetClose: ((Double?) -> Int)? = nil) {
        self.trade = trade
        self.onEdit = onEdit
        self.onPersist = onPersist
        self.onRecordPsychology = onRecordPsychology
        self.onRecordDiscipline = onRecordDiscipline
        self.sharedClose = sharedClose
        self.trailingStopPct = trailingStopPct
        self.onSetClose = onSetClose
        _peakText  = State(initialValue: trade.peakUnderlying.map { String(format: "%g", $0) }
                                         ?? DebugHooks.prefillPeak)
        // ★ 当天该标的已经填过收盘价的话,直接带出来 —— 不用再查一遍。
        _closeText = State(initialValue: (trade.finalUnderlying ?? sharedClose)
                            .map { String(format: "%g", $0) } ?? DebugHooks.prefillClose)
        _peakTime  = State(initialValue: trade.fills.map(\.time).max() ?? Date())
    }

    /// 逐笔成交的脚注。三种情况说三种话。
    private var fillsFootnote: String {
        if trade.hasEstimatedTimes {
            return Loc.t("时刻按交易所时区(纽约)。\n★ `--:--` = **这笔成交的时间没填过** —— 录入时留的是默认值,不是券商给的。点右上角「改」补上,盈亏不受影响。")
        }
        if trade.looksLikeLegacyDefaultTime {
            return Loc.t("时刻按交易所时区(纽约)。\n★ 这几笔**正好都是 11:00** —— 那是 v3.2 之前录入页的默认时刻,很可能没填过。真是 11:00 成交就不用管;不是的话点「改」补上,**盈亏和统计都不受影响**。")
        }
        return Loc.t("时刻按交易所时区(纽约)—— 和归日、周期分桶用的是同一个时区。")
    }

    /// 图上用的短标签。完整措辞留给下面的卡片 —— 图里塞长句会溢出,而且看不清。
    static func shortLabel(_ id: String) -> String { counterfactualShortLabel(id) }

    /// 把界面上正在编辑的值套到 trade 上再算。
    /// ★ 2026-09-01 实测抓到的 bug:我只在点「完成」时把 `userClosePrice` 写回 trade,
    ///   而反事实是从 trade 算的 —— 于是**输入框里打了 0.25,下面的数一动不动**。
    ///   用户会以为「填了没用」。⇒ 编辑中的值必须参与计算,不能等保存。
    private var liveTrade: Trade {
        var t = trade
        for i in t.legs.indices {
            if let v = closePxText[t.legs[i].id].flatMap(Double.init) {
                t.legs[i].userClosePrice = v
            }
            if t.legs[i].path?.isEmpty ?? true, let p = fetchedPaths[t.legs[i].id] {
                t.legs[i].path = p
            }
        }
        if t.underlyingPath?.isEmpty ?? true, let u = fetchedUnderlying { t.underlyingPath = u }
        return t
    }

    private var result: (results: [Counterfactual], vols: [UUID: Double], missing: [DataRequirement]) {
        CounterfactualEngine.allByTime(
            trade: liveTrade,
            peakUnderlying: Double(peakText),
            peakTime: usePeakTime ? peakTime : nil,
            finalUnderlying: Double(closeText),
            trailingStopPct: trailingStopPct)
    }

    /// 这笔的真实路径事实。没有路径就返回 nil —— **不编**。
    private var pathFacts: (mae: Double, mfe: Double, capture: Double?, bars: Int)? {
        let t = liveTrade
        for leg in t.legs {
            guard let raw = leg.path, !raw.isEmpty,
                  let entryFill = t.openingFills(of: leg).first,
                  let side = t.openingSide(of: leg) else { continue }
            let entry = entryFill.price
            // ★ MAE / MFE 的定义是「**持仓期间**」—— 路径现在取到当天收盘,
            //   不切窗就会把你走之后的极值算进来(实测 −11.2% 会变成 −93.3%)。
            let p = PathAnalysis.slice(raw, from: entryFill.time,
                                       to: t.closingFills(of: leg).last?.time)
            guard !p.isEmpty else { continue }
            let long = side == .buy
            guard let mae = PathAnalysis.trueMAE(path: p, entry: entry, isLong: long),
                  let mfe = PathAnalysis.trueMFE(path: p, entry: entry, isLong: long)
            else { continue }
            let exit = t.closingFills(of: leg).last?.price
            return (mae, mfe,
                    exit.flatMap { PathAnalysis.mfeCapture(path: p, entry: entry,
                                                           exit: $0, isLong: long) },
                    p.count)
        }
        return nil
    }

    /// 该腿到期内在价值 —— 只当**占位提示**用,明确标成估算。
    private func estimateText(for leg: Leg) -> String {
        guard case .option(let right, let strike, _) = leg.kind,
              let u = Double(closeText) else { return Loc.t("可留空") }
        let iv = max(right == .call ? u - strike : strike - u, 0)
        return String(format: Loc.t("估算 %.2f"), iv)
    }

    /// ★ 唯一联网处。只发「代码 + 日期」,取回来**填进输入框**,不直接存。
    @MainActor
    private func autofill() async {
        guard let key = trade.tradingDayKey,
              let day = TradingDay.date(fromKey: key) else { return }
        fetching = true; fetchNote = nil
        defer { fetching = false }
        // ★ 期货/外汇在 Yahoo 上有后缀(MNQ -> MNQ=F,EURUSD -> EURUSD=X)。
        //   2026-09-01 实测:直接拿 trade.symbol 去查 MNQ 会返回一坨看不懂的东西 ——
        //   **代码映射要和分钟 K 用同一份**,不能一处映射、一处不映射。
        let quoteSymbol = trade.legs.first
            .flatMap { QuoteService.yahooSymbol(for: $0.kind, tradeSymbol: trade.symbol) }
            ?? trade.symbol
        do {
            let bar = try await QuoteService.dailyBar(symbol: quoteSymbol, on: day)
            closeText = String(format: "%g", (bar.close * 100).rounded() / 100)
            affected = onSetClose?(bar.close) ?? 0
            // 峰值:做多看当日最高,做空看当日最低
            let long = trade.legs.first.flatMap { trade.openingSide(of: $0) } != .sell
            if peakText.isEmpty {
                let pk = long ? bar.high : bar.low
                peakText = String(format: "%g", (pk * 100).rounded() / 100)
            }
            fetchNote = String(
                // ★ `Loc.t(cond ? "A" : "B")` 抽取器认不出来(它只认紧跟在
                //   `Loc.t(` 后面的字面量)—— 写成两个独立调用才查得到。
                format: long
                    ? Loc.t("已填 %1$@ 的收盘 %2$@、当日最高 %3$@ —— 数字不对就直接改,改了以你的为准。")
                    : Loc.t("已填 %1$@ 的收盘 %2$@、当日最低 %3$@ —— 数字不对就直接改,改了以你的为准。"),
                key, String(format: "%.2f", bar.close),
                String(format: "%.2f", long ? bar.high : bar.low))
        } catch {
            // ★ 日 K 取不到不该挡住分钟 K —— 两件事,失败各算各的。
            fetchNote = (error as? QuoteService.Failure)?.errorDescription
                ?? Loc.t("取不到日线。手动填也一样能算。")
        }

        let note = await fetchCandles(day: day)
        if let note { fetchNote = (fetchNote ?? "") + note }
    }

    /// 抓**真实分钟 K**。实测 Yahoo 的 1m 免费可用:
    /// 股票/ETF 391 根、期货 1439 根、外汇 1280 根,12 个内置期货合约全有。
    /// <b>但只回溯 29 天</b>,更早的只能画示意图(所以示意 K 线不能删)。
    /// ⚠️ 期权拿不到自己的价 —— 那条路只能走 tools/moomoo_enrich.py。
    ///   但**标的**的分钟 K 是免费的,至少能看出当时是趋势还是来回磨。
    ///
    /// ★★ 2026-09-03 从 `autofill()` 里拆出来:用户报「添加订单之后收盘了
    ///   也没显示当天 K 线」。原因不是抓不到,是**它只挂在那个按钮上** ——
    ///   不点「自动填标的价」就永远不抓。<b>能力早就有了,触发条件是错的。</b>
    @MainActor
    private func fetchCandles(day: Date) async -> String? {
        var filled: [String] = []
        var edited = trade
        for i in edited.legs.indices where edited.legs[i].path?.isEmpty ?? true {
            guard let sym = QuoteService.yahooSymbol(for: edited.legs[i].kind,
                                                     tradeSymbol: trade.symbol),
                  let bars = try? await QuoteService.minuteBars(symbol: sym, on: day),
                  !bars.isEmpty else { continue }
            edited.legs[i].path = bars
            fetchedPaths[edited.legs[i].id] = bars
            filled.append(String(format: Loc.t("%1$@ %2$lld 根"),
                                 edited.legs[i].display, bars.count))
        }
        if edited.underlyingPath?.isEmpty ?? true,
           edited.legs.contains(where: { $0.kind.isOption }) {
            do {
                let bars = try await QuoteService.minuteBars(symbol: trade.symbol, on: day)
                if !bars.isEmpty {
                    edited.underlyingPath = bars
                    fetchedUnderlying = bars
                    filled.append(String(format: Loc.t("标的 %1$@ %2$lld 根"),
                                         trade.symbol, bars.count))
                }
            } catch is CancellationError {
                // 被取消不是失败,也不该报「连不上网」—— 下次进来重试。
                candleWasCancelled = true
            } catch {
                // ★ 取不到就**说出来**。默默不画,用户只看到「没有 K 线」,
                //   而不知道是超过 29 天、还是断网、还是代码不对。
                candleFailure = (error as? QuoteService.Failure)?.errorDescription
            }
        }
        guard !filled.isEmpty else { return nil }
        onPersist?(edited)
        return String(format: Loc.t("\n已抓到真实分钟 K:%@"), filled.joined(separator: "、"))
    }

    /// 打开复盘页时自动补当天的 K 线。
    ///
    /// ★ 一次生命周期只试一次 —— 失败(比如超过 29 天)不该每次滚动都重打一遍网络。
    /// ★ 可以关掉(数据页的开关)。**引导页那句「只有你点按钮时才联网」
    ///   已经跟着改了** —— 承诺和行为必须对得上。
    @MainActor
    private func autoFetchCandlesIfNeeded() async {
        guard autoFetchCandles, !triedAutoFetch else { return }
        triedAutoFetch = true
        guard needsCandles,
              let key = trade.tradingDayKey,
              let day = TradingDay.date(fromKey: key) else { return }
        fetching = true
        defer { fetching = false }
        let note = await fetchCandles(day: day)
        // ★ `.task` 会在视图消失时被**取消**。而「记完 → 问原因 → 复盘页」这一串里
        //   sheet 内容是换掉的,请求可能刚发出去就被掐断 —— 那不叫「试过了」,
        //   <b>也绝不该报成「连不上网」</b>(2026-09-03 实测踩到)。
        if candleWasCancelled || Task.isCancelled {
            triedAutoFetch = false
            candleWasCancelled = false
            return
        }
        if let note {
            fetchNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let why = candleFailure {
            fetchNote = why
        }
    }

    /// 还缺 K 线吗?★ 期权看**标的**那条(它自己的历史价没有免费源)。
    private var needsCandles: Bool {
        if liveTrade.legs.contains(where: { $0.kind.isOption }) {
            return liveTrade.underlyingPath?.isEmpty ?? true
        }
        return liveTrade.legs.contains { $0.path?.isEmpty ?? true }
    }

    // ★ ReviewView 的 body 也开始报「无法在合理时间内完成类型检查」。
    //   同一个病:SwiftUI 按**整个表达式**算类型检查预算。拆开是唯一的修法。
    @ViewBuilder private var limitsSection: some View {
        // ★ 有了真实分钟路径,这两条就不该再挂着 —— 清单要跟着能力走。
        // ★★ 2026-09-24:改成**默认折叠**,放在最底下。
        //   原来它是一个完整区块,标题「这一版算不了的」,里面还有一句
        //   「电脑上跑 `tools/moomoo_enrich.py` 把备份补全再导回来」——
        //   <b>那是写给开发者的操作说明,不是给一个不写代码的用户看的。</b>
        let hasPath = trade.legs.contains { !($0.path?.isEmpty ?? true) }
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if hasPath {
                        Label(md: "移动止损、真 MAE / MFE **已经能算了** —— 这笔有真实分钟路径",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.profit)
                    } else {
                        Label("「平一半 + 剩余移动止损」的完整版 —— 何时触发要分钟级路径",
                              systemImage: "minus.circle")
                        Label("真正的 MAE —— 只能从成交点观测,所以上面写的是「≥」",
                              systemImage: "minus.circle")
                    }
                    Label("期权的历史价 App 内取不到 —— 没有免费源,所以那格是估算,由你改",
                          systemImage: "minus.circle")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 4)
            } label: {
                Text("这一笔还有哪些算不了").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var optionClosePriceSection: some View {
        // ★★ 「持有到收盘」= 收盘时**卖掉**(拿市场价);
        //    「持有到到期」= 放到归零(拿内在价值)。**对 0DTE 这两个数差的就是全部。**
        //    用户 2026-09-01:「我这张 708 的 call 收盘的时候实际上只有 0.25」——
        //    模型算 0,事实是 0.25,3 张就差 $75,占那笔盈利的 23%。
        //    历史期权价没有免费源,所以:给估算、标明是估算、让你一眼改掉。
        if trade.isClosed, trade.legs.contains(where: { $0.kind.isOption }) {
            Section {
                ForEach(trade.legs.filter { $0.kind.isOption }) { leg in
                    // ⚠️ 更正:我一度断定「LabeledContent 里的空 TextField 点不到」,
                    //   为此改成 HStack 又加了 frame —— **两次都是错的诊断**。
                    //   真正的原因是**我自己算错了点击坐标**(拿 1932 当图高,实际 2000),
                    //   一直点在行外面。LabeledContent 本来就没问题。
                    //   ★ 又一次「改对了代码 ≠ 诊断对了」。留 HStack 只是因为它已经在跑,
                    //     不是因为 LabeledContent 有毛病。
                    HStack {
                        Text(verbatim: leg.display)
                        // i18n-ok:estimateText 内部已经 Loc.t 过
                        TextField(estimateText(for: leg),
                                  text: Binding(
                                    get: { closePxText[leg.id] ?? "" },
                                    set: { closePxText[leg.id] = $0 }))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("收盘时这条腿的真实价")
            } footer: {
                Text(md: "留空就用**模型估算**(到期的内在价值)。但末日期权收盘时往往还有几分钱时间价值 —— **去券商的历史行情里看一眼真实价填进来**,「若持有到收盘」那条才是真的。")
            }
        }

    }

    @ViewBuilder private var candleSection: some View {
        let hasRealUnderlying = !(liveTrade.underlyingPath?.isEmpty ?? true)
        ForEach(liveTrade.legs) { leg in
            let bars = SyntheticPath.bars(for: liveTrade, leg: leg)
            let isReal = !(leg.path?.isEmpty ?? true)
            // ★ 真的永远画;编的只在「什么真数据都没有」时画 —— 那时它是唯一的图
            if !bars.isEmpty, isReal || !hasRealUnderlying {
                Section {
                    CandleChart(bars: bars,
                                marks: liveTrade.fills(of: leg).map {
                                    CandleChart.Mark(px: $0.price, isBuy: $0.side == .buy)
                                },
                                isReal: !(leg.path?.isEmpty ?? true))
                } header: {
                    Text(trade.isMultiLeg ? "走势 · \(leg.display)" : "走势")
                }
            }
        }
        // ★ 期权拿不到自己的历史价,但**标的**的分钟 K 是免费的。
        //   看不到那张期权怎么走,至少能看到当时是趋势还是来回磨。
        //   ⚠️ 必须写清「这不是期权的价格」—— 否则就是拿一条曲线冒充另一条。
        if let up = liveTrade.underlyingPath, !up.isEmpty,
           liveTrade.legs.contains(where: { $0.kind.isOption }) {
            Section {
                CandleChart(bars: up, marks: [], isReal: true, height: 110)
            } header: {
                Text("标的 \(trade.symbol) 当天走势")
            } footer: {
                Text(md: String(format: Loc.t("这是 **%@ 本身**的分钟 K,**不是这张期权的价格** —— 期权的历史价没有免费源。它只用来看当时是趋势还是来回磨。"),
                                trade.symbol))
            }
        }
    }

    @ViewBuilder private var pathFactsSection: some View {
        // ★★ 真 MAE / 真 MFE / MFE 捕获率 —— 这三个数以前只能写「≥」或者用 BS 估,
        //    现在有真实分钟路径就是**真的**。
        if let facts = pathFacts {
            Section {
                LabeledContent("真 MAE(最难受的时候)") {
                    // 0% 用红色看着像出了事;只有真的回撤过才染红。
                    Text(String(format: "%.1f%%", facts.mae))
                        .foregroundStyle(facts.mae < -0.05 ? Theme.loss : Color.secondary)
                }
                LabeledContent("真 MFE(最好的时候)") {
                    Text(String(format: "+%.1f%%", facts.mfe)).foregroundStyle(Theme.profit)
                }
                if let cap = facts.capture {
                    LabeledContent("你吃到了其中") {
                        Text(String(format: "%.0f%%", cap * 100)).fontWeight(.semibold)
                    }
                }
            } header: {
                Text("真实路径(不是模型估的)")
            } footer: {
                Text(md: String(format: Loc.t("来自 **%lld 根分钟 K**,百分比是**相对你的入场价**(不是账户、也不是标的)。以前 MAE 只能从成交点看,所以写「≥」;现在是真的。"),
                                facts.bars))
            }
        }

    }

    @ViewBuilder private var inputsSection: some View {
        Section {
            LabeledContent("峰值时标的价") {
                // 让输入框占满整块值区:空值时点起来更容易。
                // (⚠️ 加它时我以为是在修一个 bug,后来查明那个 bug 是我点错了坐标 ——
                //   它只是个小改善,不是修复。)
                TextField("可留空", text: $peakText).keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !peakText.isEmpty, trade.legs.contains(where: { $0.kind.isOption }) {
                Toggle("峰值出现的时刻", isOn: $usePeakTime)
                if usePeakTime {
                    DatePicker("", selection: $peakTime).labelsHidden()
                }
            }
            LabeledContent("收盘/强平时标的价") {
                TextField("填一次,当天共用", text: $closeText).keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onChange(of: closeText) { _, v in
                        affected = onSetClose?(Double(v)) ?? 0
                    }
            }
            if affected > 1 {
                Label("已应用到当天全部 \(affected) 笔 \(trade.symbol) 交易",
                      systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Theme.profit)
            }
            // ★ 唯一联网处:只发「代码 + 日期」,取当天 O/H/L/C。
            //   取回来是**填进输入框**,不是直接存 —— 你仍然能改。
            Button { Task { await autofill() } } label: {
                HStack {
                    if fetching { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.down.circle") }
                    Text(fetching ? "查行情中…" : "自动填标的价")
                }
            }
            .disabled(fetching || trade.tradingDayKey == nil)
            if let n = fetchNote {
                Text(verbatim: n).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            // ★ 改名:它挪到了页面最底下,上面的提示指的就是这个名字
            Text("补充数据(可选)")
        } footer: {
            if !peakText.isEmpty && !usePeakTime && trade.legs.contains(where: { $0.kind.isOption }) {
                Text(md: "不填峰值时刻的话,按**出场时刻**近似 —— 0DTE 差两小时和差两分钟不是一回事。")
            }
        }

    }

    var body: some View {
        List {
            // ★★ 2026-09-24 美化:**结论先行**。
            //   原来打开一笔交易,最先看到的是两个「可留空」的输入框,
            //   接着是一张「形状是编的,别从图上读价格」的示意 K 线 ——
            //   <b>盈亏排在第九个区块</b>。标题只写日期,连是哪张合约都不说。
            //   ⇒ 头卡放最上面:合约、时刻、盈亏、收益率、一句结论。
            Section {
                ReviewHeader(trade: liveTrade, results: result.results)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)

            // ★ 主视觉:分叉图。它画的就是 App 图标那件事 ——
            //   一条实线是你走的,几条虚线是你没走的。
            if !result.results.isEmpty {
                Section {
                    ForkChart(actualPnL: trade.realizedPnL,
                              branches: result.results.map {
                                  (Self.shortLabel($0.id), $0.alternativePnL,
                                   $0.verdict == .alternativeWasBetter)
                              })
                } footer: {
                    // ★ 原文写的是「我们没有分钟级数据」—— v1.8 起这句不再成立
                    //   (股票/期货/外汇点一下就有,期权仍然没有)。
                    //   这张图的横轴本来也不是时间,说清它是什么就够了,别再拿数据说事。
                    // ★ 原来这里是四行解释,还指向「上面那张 K 线」—— K 线现在挪到下面了。
                    Text("横轴不是时间 —— 只画「出场」这一个分岔口。实线是你,虚线是你没走的。")
                    .font(.caption2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }

            if result.results.isEmpty {
                Section {
                    Label("在页面最下面「补充数据」里填上收盘价,这里就会出现「如果换个做法会怎样」。",
                          systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary).font(.footnote)
                }
            }
            ForEach(result.results) { cf in
                Section { CounterfactualCard(cf: cf) }
            }

            // ★★ K 线:有真实分钟数据就画真的。**示意的那张只在什么真数据都没有时才画** ——
            //    原来已经抓到 390 根真实分钟 K 了,上面还摆着一张「形状是编的」图。
            candleSection
            pathFactsSection

            // ── 逐腿明细:多腿组合必须看得见每条腿贡献了多少 ──
            if trade.isMultiLeg {
                Section("逐腿明细") {
                    ForEach(trade.legs) { leg in LegRowView(trade: trade, leg: leg, vols: result.vols) }
                    LabeledContent("合计") {
                        Text(verbatim: Money.signed(trade.realizedPnL))
                            .fontWeight(.semibold).monospacedDigit()
                            .foregroundStyle(Theme.pnl(trade.realizedPnL))
                    }
                }
            }

            Section("这笔") {
                if trade.isMultiLeg {
                    LabeledContent("策略") {
                        Text(verbatim: String(format: Loc.t("%1$@ · %2$lld 腿"),
                                              Loc.t(trade.strategy.rawValue), trade.legs.count))
                    }
                }
                // ★ 盈亏、收益率、成本都在最上面的头卡里 —— 这里原来又写了一遍,
                //   而且还是 `US$498` 的旧写法。只留头卡没写的那种情况:贷记开仓。
                if trade.isClosed, trade.returnOnDebit == nil, trade.netCredit > 0 {
                    // 贷记开仓:分母应该是占用的保证金/最大风险,App 没有这个数
                    // ⇒ **说清算不了**,而不是拿收到的权利金当本金硬算一个百分比
                    LabeledContent("收益率") {
                        Text("贷记开仓 · 算不了").foregroundStyle(.secondary).font(.footnote)
                    }
                    LabeledContent("净贷记(开仓收钱)") {
                        Text(verbatim: Money.plain(trade.netCredit)).monospacedDigit()
                    }
                }
                if let e = trade.entryClock {
                    LabeledContent("开仓时刻") {
                        Text(verbatim: trade.exitClock.map { "\(e) → \($0)" } ?? e)
                            .monospacedDigit()
                    }
                }
                if let er = trade.entryReason {
                    LabeledContent("开单原因") {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey(er))
                            if trade.reasonsRecordedAfterOutcome {
                                // ★ 和心理状态同一个规矩:事后补的就标出来
                                Pill(text: Loc.t("事后补的"), tint: Theme.warn)
                            }
                        }
                    }
                }
                if let xr = trade.exitReason {
                    LabeledContent("出场原因") { Text(LocalizedStringKey(xr)) }
                }
                if let onRecordDiscipline {
                    Button {
                        onRecordDiscipline()
                    } label: {
                        LabeledContent("纪律自检") {
                            if let d = trade.discipline, !d.isEmpty {
                                Text(verbatim: String(format: Loc.t("答了 %1$lld · 没做到 %2$lld"),
                                                      d.answered, d.broken.count))
                                    .foregroundStyle(d.broken.isEmpty ? Color.secondary : Theme.warn)
                            } else {
                                Text("还没做").foregroundStyle(Theme.warn)
                            }
                        }
                    }
                    .foregroundStyle(Color.primary)
                }
                if !trade.isMultiLeg {
                    LabeledContent("开仓均价 / 出场",
                                   value: "\(trade.averageEntry.f2) → \(trade.averageExit.f2)")
                }
                if let mae = CounterfactualEngine.observedMAE(trade: trade) {
                    LabeledContent("最大浮亏") {
                        Text("≥ \(mae.pct.f1)%").foregroundStyle(Theme.loss).monospacedDigit()
                    }
                }
            }

            // ── 逐笔成交:加仓和分批平只有摊在这里才看得清 ──
            //    ★ 用户 2026-09-03:「订单里面没显示具体开单时间」。
            //      均价掩盖了过程:「2 张 @2.17 + 1 张 @1.57」和「3 张 @1.97」
            //      算出来的均价一样,但那是两笔完全不同的单。
            if trade.fills.count > 1 {
                Section {
                    ForEach(trade.fills.sorted { $0.time < $1.time }) { f in
                        HStack(spacing: 8) {
                            // ★ 时间是 App 填的默认值时显示 `--:--` ——
                            //   宁可空着,也不拿占位值冒充成交时刻。
                            Text(verbatim: f.timeIsEstimated
                                 ? "--:--" : TradingDay.clock(of: f.time))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(f.timeIsEstimated ? .tertiary : .secondary)
                                .frame(width: 46, alignment: .leading)
                            Text(f.side == .buy ? "买" : "卖")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(f.side == .buy ? Theme.buy : Theme.sell)
                            Text(verbatim: f.quantity.clean).font(.subheadline.monospacedDigit())
                            if let leg = trade.legs.first(where: { $0.id == f.legID }) {
                                Text(verbatim: leg.kind.localizedUnit)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(verbatim: "@ " + f.price.f2)
                                .font(.subheadline.monospacedDigit())
                            if trade.isMultiLeg,
                               let leg = trade.legs.first(where: { $0.id == f.legID }) {
                                Text(verbatim: leg.kind.shortLabel)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("逐笔成交")
                } footer: {
                    // ★ `Text(md: cond ? "A" : "B")` 抽取器认不出来 ——
                    //   它只认紧跟在 `md:` 后面的字面量。各包各的 `Loc.t`。
                    Text(md: fillsFootnote)
                }
            }

            if !trade.attachments.isEmpty {
                Section("开仓时看到的图") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(trade.attachments) { a in
                                ChartThumb(store: AttachmentStore.default(), attachment: a, onDelete: nil)
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }

            Section {
                if let psy = trade.psychology {
                    HStack {
                        Pill(text: psy.beforeOutcome ? Loc.t("开仓前记的") : Loc.t("事后补的"),
                             tint: psy.beforeOutcome ? Theme.profit : Theme.warn)
                        Spacer()
                        Text("信心 \(psy.confidence)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(verbatim: psy.states.localizedJoined)
                        .font(.subheadline)
                        .foregroundStyle(psy.hasRedFlag ? Theme.warn : Color.primary)
                    if let p = psy.plan, !p.isEmpty {
                        Text(verbatim: p).font(.callout).foregroundStyle(.secondary)
                    }
                    if !psy.beforeOutcome {
                        Text(md: "★ 事后补的**不参与任何统计** —— 你已经知道结果了,这时候选的心情必然被结果带着走。")
                        .font(.caption2).foregroundStyle(Theme.warn)
                    }
                } else {
                    Button { onRecordPsychology?() } label: {
                        Label("补记当时的状态", systemImage: "brain.head.profile")
                    }
                    Text(md: "下次试试**开仓前**就记 —— 那样才算数。列表左上角有入口。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } header: { Text("开仓时的状态") }

            if let raw = trade.rawNoteAtEntry, !raw.isEmpty {
                Section("开仓时你的原话") {
                    Text(verbatim: raw).font(.callout)
                }
            }

            if !result.vols.isEmpty {
                Section {
                    ForEach(trade.legs.filter { result.vols[$0.id] != nil }) { leg in
                        LabeledContent(leg.display) {
                            Text("IV \(((result.vols[leg.id] ?? 0) * 100).f2)%").monospacedDigit()
                        }.font(.caption)
                    }
                    Text(md: "IV 由**各腿自己的成交价**反解,**交易时间口径**(252 交易日 × 6.5 小时)。换成日历口径会得到 2 倍量级的数 —— 那是错的。")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            // ★ 可选的补充数据挪到最底下 —— 它们是「给反事实喂数」的输入,不是这一页要回答的问题。
            inputsSection
            optionClosePriceSection

            limitsSection
        }
        .onAppear {
            for leg in trade.legs where closePxText[leg.id] == nil {
                if let v = leg.userClosePrice { closePxText[leg.id] = String(format: "%g", v) }
            }
        }
        // ★ 自动补当天 K 线。用户 2026-09-03:「添加订单之后收盘了也没显示当天 k 线」。
        .task { await autoFetchCandlesIfNeeded() }
        .navigationTitle(Text(verbatim: ReviewHeader.contractTitle(trade)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onEdit {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss(); onEdit() } label: { Label("改", systemImage: "pencil") }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    // 填过的价位要存下来,否则历史分析里这一笔就是空的
                    var t = trade
                    t.peakUnderlying  = Double(peakText)
                    t.finalUnderlying = Double(closeText)
                    t.peakTime = usePeakTime ? peakTime : nil
                    for i in t.legs.indices {
                        t.legs[i].userClosePrice = closePxText[t.legs[i].id].flatMap(Double.init)
                    }
                    if t.peakUnderlying != trade.peakUnderlying
                        || t.finalUnderlying != trade.finalUnderlying
                        || t.peakTime != trade.peakTime
                        || t.legs.map(\.userClosePrice) != trade.legs.map(\.userClosePrice) {
                        onPersist?(t)
                    }
                    dismiss()
                }
            }
        }
    }
}

/// 逐腿一行。做空腿的「入场」显示的是卖出价 —— 这是旧版本的一个真 bug,现在有测试守着。
struct LegRowView: View {
    let trade: Trade
    let leg: Leg
    let vols: [UUID: Double]

    var body: some View {
        let q = trade.openedQuantity(of: leg)
        let pnl = trade.legPnL(leg)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(q > 0 ? "买" : "卖")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(q > 0 ? Theme.buy : Theme.sell)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((q > 0 ? Theme.buy : Theme.sell).opacity(0.13), in: Capsule())
                Text(LocalizedStringKey(leg.kind.shortLabel)).font(.subheadline.weight(.medium))
                Text("×\(abs(q).clean)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if trade.legIsClosed(leg) {
                    Text(verbatim: Money.signed(pnl))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.pnl(pnl))
                } else {
                    Text("未平").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text("\(trade.legEntry(leg).f2)")
                if let x = trade.legExit(leg) { Text("→ \(x.f2)") }
                if let n = leg.note { Text("· \(n)") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

struct CounterfactualCard: View {
    let cf: Counterfactual

    /// ★★ 2026-09-01 用户提的:「亏损用红色,盈利才是绿色」。
    ///
    ///   原来这里画的是 `cf.delta = 替代方案 − 你`,所以「你更好」时是**负数配绿色** ——
    ///   屏幕上就出现了**绿色的减号**,读起来像「绿色的亏损」。
    ///
    ///   ⇒ 修法不是把绿色改掉,而是**把数字翻到你这边**:
    ///     显示 `你 − 替代方案`。你更好 = **正数 + 绿**,你更差 = **负数 + 红**。
    ///     符号、颜色、语义三者从此一致,不用再靠徽章去解释符号。
    private var yourEdge: Double { -cf.delta }

    /// ★★ 2026-09-24:「那样会更好 / 你少赚了」原来是**红色** ——
    ///   可那是**机会成本**,不是亏损;红色的「你少赚了 $536」会被读成「亏了 $536」。
    ///   ⇒ 用 App 图标里「你没走的那条路」的琥珀色。你赢了替代做法仍然是绿。
    ///   (大号数字那一行不受影响:它是替代做法自己的盈亏,照旧亏红赚绿。)
    private var tint: Color {
        switch cf.verdict {
        case .alternativeWasBetter: return Theme.alt
        case .youWereBetter:        return Theme.profit
        case .effectivelyTied:      return .secondary
        }
    }
    /// ★★ 这里以前是 `String` —— 进了 `Text(String)` 就**永远不本地化**,
    ///   于是本地化守卫报 100%,而屏幕上这枚徽章一直是中文(用户 2026-09-02 报的)。
    ///   <b>「能不能翻」取决于类型。</b>
    private var verdictText: LocalizedStringKey {
        switch cf.verdict {
        case .alternativeWasBetter: return "那样会更好"
        case .youWereBetter:        return "你的做法更好"
        case .effectivelyTied:      return "基本一样"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: cf.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(verdictText).font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tint.opacity(0.13), in: Capsule())
            }
            // ★★ 2026-09-01 用户逮到的第二个:「拿到收盘为什么是 +648?」
            //
            //   标题问的是「**若持有到收盘**会怎样」,大号数字答的却是「**你**比它多赚多少」——
            //   <b>主语不一致</b>。于是「若持有到收盘 +US$648」被读成
            //   「持有到收盘能赚 648」,而真相是**持有到收盘会亏 327**。
            //
            //   这个误读是我在 v1.7 翻符号时造出来的:
            //   v1.7 之前显示 −723(负数),碰巧和真相同方向,所以没人发现主语错了。
            //   我修好了「绿色的减号」,却把「标题和数字说的不是一回事」带了进来。
            //
            //   ⇒ **标题问什么,大号数字就答什么。**
            //     大号 = 那样的结果(亏就红、赚就绿),差额降为第二行。
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // ★ 原来「+」和金额是两个 Text,中间有空隙 —— 合成一个
                Text(verbatim: Money.signed(cf.alternativePnL))
                    .font(.system(.title2, design: .rounded).bold().monospacedDigit())
                    .foregroundStyle(Theme.pnl(cf.alternativePnL))
                Text("(你实际 \(cf.actualPnL.usd))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(yourEdge >= 0 ? "你多赚了" : "你少赚了").font(.caption)
                Text(verbatim: Money.plain(abs(yourEdge)))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            if let n = cf.note { Text(md: n).font(.caption2).foregroundStyle(.secondary) }
            if cf.id == "exit_vs_peak" {
                Text(md: "⚠️ 峰值是事后视角,没人卖得在最高点。这一项**不能**当作「应该拿更久」的依据 —— 看上面那条「持有到收盘」。")
                .font(.caption2).foregroundStyle(Theme.warn)
            }
        }
        .padding(.vertical, 2)
    }
}

extension Double {
    var f1: String { String(format: "%.1f", self) }
    var f2: String { String(format: "%.2f", self) }
    var usd: String { String(format: self < 0 ? "−$%.0f" : "$%.0f", abs(self)) }
}


/// **复盘页的头卡** —— 这一页要回答的问题,放在第一眼的位置。
///
/// ★★ 2026-09-24 用户:「想办法美化一下」。复盘页原来打开先是两个「可留空」的输入框,
///   盈亏压在第九个区块;标题只写日期,连是哪张合约都不说。
///   ⇒ 合约 · 时刻 · 大号盈亏 · 收益率/成本 · **一句结论**。
///
/// ★ 那句结论用图标的两种颜色:替代做法更好 = 琥珀(你没走的那条路),
///   你赢过了所有替代做法 = 赚的绿。和分叉图的实线 / 虚线是同一个意思。
struct ReviewHeader: View {
    let trade: Trade
    let results: [Counterfactual]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ★ 合约名已经在标题栏了,这里不再重复 —— 第一行只放时刻和标签
            HStack(spacing: 8) {
                Text(verbatim: timeLine)
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if !trade.addsWhileUnderwater.isEmpty {
                    Pill(text: Loc.t("逆势加仓"), tint: Theme.warn)
                }
                if trade.isSample { Pill(text: Loc.t("示例")) }
            }

            if let pnl = trade.displayablePnL {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: Money.signed(pnl))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.pnl(pnl))
                        .minimumScaleFactor(0.6).lineLimit(1)
                    if let r = trade.returnOnDebit {
                        Text(verbatim: Money.pct(r))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.pnl(pnl).opacity(0.85))
                    }
                }
                // ★ 2026-10-06 加「持仓多久」:和成本摆在一行,不知道的那一项就不写
                let meta = [trade.netDebit > 0 ? String(format: Loc.t("成本 %@"), Money.plain(trade.netDebit)) : nil,
                            trade.holdingSeconds.map { String(format: Loc.t("持仓 %@"), HoldingTime.format($0, Loc.t)) }]
                    .compactMap { $0 }
                if !meta.isEmpty {
                    Text(verbatim: meta.joined(separator: "  ·  "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: String(format: Loc.t("未平仓 · 在手 %1$@ %2$@"),
                                      trade.openQuantity.clean,
                                      trade.legs.first?.kind.localizedUnit ?? ""))
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.open)
            }

            if let v = verdict {
                HStack(spacing: 6) {
                    Image(systemName: v.better ? "arrow.triangle.branch" : "checkmark.seal.fill")
                    Text(md: v.text)
                }
                .font(.subheadline)
                .foregroundStyle(v.better ? Theme.alt : Theme.profit)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((v.better ? Theme.alt : Theme.profit).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(Theme.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    /// 一句结论:最好的替代做法比你多赚多少 —— 或者你赢过了所有替代做法。
    private var verdict: (text: String, better: Bool)? {
        guard trade.isClosed, let best = results.max(by: { $0.alternativePnL < $1.alternativePnL })
        else { return nil }
        let d = best.alternativePnL - trade.realizedPnL
        if d > 0.5 {
            return (String(format: Loc.t("「%1$@」会多赚 **%2$@**"),
                           ReviewView.shortLabel(best.id), Money.plain(d)), true)
        }
        return (Loc.t("比所有替代做法都好"), false)
    }

    /// `9月3日 周四 · 11:05 → 11:40`。隔夜单写两个日期。
    private var timeLine: String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = TradingDay.exchangeTimeZone; f.locale = Loc.locale
        f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        guard let open = trade.fills.map(\.time).min() else { return "" }
        var s = f.string(from: open)
        if let e = trade.entryClock { s += " · " + e }
        if let x = trade.exitClock {
            let closeDay = trade.realizedAt.map { TradingDay.key(of: $0) }
            if let cd = closeDay, cd != TradingDay.key(of: open), let r = trade.realizedAt {
                s += "  →  " + f.string(from: r) + " " + x      // 隔夜:把平仓那天也写上
            } else {
                s += "  →  " + x
            }
        }
        return s
    }

    /// `QQQ 713C` / `BEX` / `QQQ 铁鹰`。★ 标题栏也用它 —— 原来标题只写日期。
    static func contractTitle(_ t: Trade) -> String {
        if t.isMultiLeg { return "\(t.symbol) \(Loc.t(t.strategy.rawValue))" }
        guard let leg = t.primaryLeg else { return t.symbol }
        if case .option = leg.kind { return "\(t.symbol) \(leg.kind.shortLabel)" }
        return t.symbol
    }
}
