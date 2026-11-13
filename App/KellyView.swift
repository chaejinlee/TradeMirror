import SwiftUI

/// **凯利仓位** —— 填预算,看 ¼ / ½ / 满凯利每笔各是多少权利金。
///
/// ★ 用户 2026-10-04:「根据凯利公式以及我们的历史战绩来算最优仓位」→
///   「做进 app 里,我可以随时修改预算来计算对应仓位」。
///
/// ★★ 那个数旁边必须摆着它有多不可靠:误差多大、一笔归零会怎样、照着做会回撤多深。
///   算法和理由都在引擎 `Kelly` 里(有测试);这里只负责摆出来。
struct KellyView: View {
    @Environment(\.dismiss) private var dismiss
    let trades: [Trade]

    /// 预算(美元)。★ 存在本机,随时改、立刻重算;0 = 还没填。
    @AppStorage("kellyBudget") private var budget: Double = 0
    @State private var text = ""
    @FocusState private var focused: Bool
    /// ★ 重抽 + 回撤表放到后台算,别卡住界面(手机上的包开了 -O,0.04 秒;模拟器的 Debug 包要两秒多)。
    ///   预算、倍数、标准都只是查表,不用重算。
    @State private var report: Kelly.Report?
    /// 自选倍数(× 满凯利)、期限、回撤标准 —— 都存本机,下次打开还是上次的选择。
    /// ★ 用户 2026-10-05:「在控制回撤的情况下应该使用多少凯利」→「做进去 app」。
    ///   用几成是**他**的事:App 只摆出每个倍数会回撤多深、每条标准允许多大倍数。
    @AppStorage("kellyMultiple") private var multiple: Double = 0.25
    @AppStorage("kellyHorizon") private var horizon: Int = 100
    @AppStorage("kellyDDDepth") private var ddDepth: Double = 0.3
    @AppStorage("kellyDDProb") private var ddProb: Double = 0.1

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    budgetCard
                    if let r = report {
                        if !r.enough {
                            notEnough(r)
                        } else {
                            sizing(r)
                            if let sw = r.sweet { sweetCard(r, sw) }
                            if let g = r.grid {
                                custom(r, g)
                                lookup(r, g)
                            }
                            reliability(r)
                            ruin(r)
                            footnote(r)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding()
            }
            .navigationTitle("凯利仓位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focused = false }
                }
            }
            .task {
                if text.isEmpty, budget > 0 { text = String(Int(budget)) }
                let ts = trades
                report = await Task.detached { Kelly.report(ts) }.value
            }
        }
    }

    // MARK: - 预算

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("预算").font(.headline)
                Spacer()
                Text(verbatim: "$").foregroundStyle(.secondary)
                // ★ 数字键盘没有 Return 键:边打边存(HistoryView 那张卡踩过一次)
                TextField("填金额", text: $text)
                    .keyboardType(.numberPad).focused($focused)
                    .multilineTextAlignment(.trailing).frame(width: 140)
                    .font(.title3.monospacedDigit())
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: text) { _, v in
                        let digits = String(v.filter(\.isASCII).filter(\.isNumber).prefix(10))
                        if digits != v { text = digits; return }
                        budget = Double(digits) ?? 0
                    }
            }
            Text(md: "准备拿来做这类期权交易的**全部本金**。凯利算的是每笔占这笔钱的比例 —— 改了下面立刻跟着变。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: - 每笔多少

    private func sizing(_ r: Kelly.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每笔权利金").font(.headline)
            if r.fStar <= 0 {
                Text(md: "这段战绩**平均每笔不赚钱** —— 凯利公式的答案是 0。")
                    .font(.subheadline)
            } else {
                // ★ 表头不许折行:英文的 Fraction 在窄列里会被断成 Frac-/tion
                HStack {
                    Text("仓位").frame(width: 64, alignment: .leading)
                    Text("比例").frame(width: 52, alignment: .trailing)
                    Spacer()
                    Text("每笔").frame(alignment: .trailing)
                    Text("\(r.horizon) 笔内回撤过半").frame(width: 112, alignment: .trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
                ForEach(r.risks, id: \.multiple) { k in
                    row(k)
                }
                if budget <= 0 {
                    Text("填上预算,这里会算出每笔多少钱。").font(.footnote).foregroundStyle(.secondary)
                }
                if r.capped {
                    Label {
                        Text(md: "**顶到 100% 了**:数据里还没有足够的亏损来约束它,这个数没有意义。")
                    } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.footnote).foregroundStyle(Theme.warn)
                }
                current(r)
            }
        }
        .card()
    }

    private func row(_ k: Kelly.Risk) -> some View {
        HStack {
            Group {
                switch k.multiple {
                case 1:   Text("满凯利")
                case 0.5: Text("½ 凯利")
                default:  Text("¼ 凯利")
                }
            }
            .font(.subheadline.weight(k.multiple == 1 ? .semibold : .regular))
            .frame(width: 64, alignment: .leading)
            Text(verbatim: Self.pct(k.f)).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Spacer()
            Text(verbatim: budget > 0 ? Money.plain(budget * k.f) : "—")
                .font(.body.monospacedDigit().weight(.semibold))
            Text(verbatim: Self.pct(k.pHalfDrawdown)).monospacedDigit()
                .foregroundStyle(k.pHalfDrawdown >= 0.5 ? Theme.loss : .primary)
                .frame(width: 112, alignment: .trailing)
        }
    }

    /// 现在每笔用的是预算的多少 —— 有了预算才算得出来。
    @ViewBuilder
    private func current(_ r: Kelly.Report) -> some View {
        if let c = r.current(budget: budget) {
            let money = Money.plain(r.recentMedianDebit)
            let share = Self.pct(c.fraction)
            Divider()
            if let k = c.ofKelly {
                let times = String(format: "%.1f", k)
                Text(md: String(format: Loc.t("你最近 %lld 笔,每笔权利金中位数 **%@** —— 是预算的 **%@**,约满凯利的 **%@ 倍**。"),
                                r.recentCount, money, share, times))
                    .font(.footnote)
            } else {
                Text(md: String(format: Loc.t("你最近 %lld 笔,每笔权利金中位数 **%@** —— 是预算的 **%@**。"),
                                r.recentCount, money, share))
                    .font(.footnote)
            }
        }
    }

    // MARK: - 甜点区

    private func sweetCard(_ r: Kelly.Report, _ sw: Kelly.SweetSpot) -> some View {
        let lo = sw.low, hi = sw.high, f = r.fStar
        return VStack(alignment: .leading, spacing: 10) {
            Text("甜点区").font(.headline)
            if hi < 0.05 {
                Text(md: "把估计误差算进去以后,**增长最大的倍数接近 0** —— 这段战绩还证明不了有优势。")
                    .font(.subheadline)
            } else {
                Group {
                    if budget > 0 {
                        Text(md: String(format: Loc.t("约 **%@–%@ 凯利**:每笔预算的 %@–%@(%@–%@)。"),
                                        Self.times(lo), Self.times(hi), Self.pct1(lo * f), Self.pct1(hi * f),
                                        Money.plain(budget * lo * f), Money.plain(budget * hi * f)))
                    } else {
                        Text(md: String(format: Loc.t("约 **%@–%@ 凯利**:每笔预算的 %@–%@。"),
                                        Self.times(lo), Self.times(hi), Self.pct1(lo * f), Self.pct1(hi * f)))
                    }
                }
                .font(.subheadline)
                sweetCurve(sw)
                // ★ 只有平均增长最大的倍数确实在 1× 以下时才这么说 —— 数据变了,这句话不能自动成立
                if sw.doubleBootstrap < 1, sw.share(at: 1.2) < 1 {
                    let s15 = sw.share(at: 1.5)
                    Group {
                        if s15 > 0 {
                            Text(md: String(format: Loc.t("**超过 1× 押得越多、增长越少**:1.2× 只剩 %@,1.5× 只剩 %@。"),
                                            Self.pct(sw.share(at: 1.2)), Self.pct(s15)))
                        } else {
                            Text(md: String(format: Loc.t("**超过 1× 押得越多、增长越少**:1.2× 只剩 %@,1.5× 变成负的。"),
                                            Self.pct(sw.share(at: 1.2))))
                        }
                    }
                    .font(.footnote)
                }
                Text(verbatim: String(format: Loc.t("怎么算的:把「%@ 是从 %lld 个交易日估出来的」算进去 —— 估多了就会押多,而押多的代价比押少大。三种算法:偏差校正 %@ · 解析 %@ · 两层重抽 %@。差这么多,是因为都取决于真实优势有多大,而这正是这 %lld 天说不清的 —— 所以给一段,不给一个点。"),
                                      Self.pct(f), r.days, Self.times(sw.biasCorrected), Self.times(sw.plugIn),
                                      Self.times(sw.doubleBootstrap), r.days))
                    .font(.footnote).foregroundStyle(.secondary)
                if let e = r.efficiency(horizon: 100), let first = e.first, let last = e.last {
                    if let k = r.efficiencyKnee(horizon: 100) {
                        Text(verbatim: String(format: Loc.t("每多承受 1%% 的回撤换来的增长,在 %@ 附近突然变差 —— 那里是拐点。"), Self.times(k)))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: String(format: Loc.t("每多承受 1%% 的回撤换来的增长(占满凯利):从 0.05× 时的 %@ 平滑降到 1× 时的 %@,没有拐点 —— 段内选哪里,看你能忍多深的回撤(用下面的反查)。"),
                                              Self.pct1(first), Self.pct1(last)))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }

    /// 平均增长 vs 押几倍。★ 甜点区铺底、1× 画一条线、滑块当前的倍数打一个点 —— 别的都是噪音。
    private func sweetCurve(_ sw: Kelly.SweetSpot) -> some View {
        let xs = sw.multiples
        let top = max(sw.growth.max() ?? 1, 1e-12)
        let ys = sw.growth.map { $0 / top }
        let xMax = xs.last ?? 1.5
        let yLo = min(0, ys.min() ?? 0)
        let c = min(max(multiple, xs.first ?? 0.05), xMax)
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height - 16
            let x = { (v: Double) in v / xMax * w }
            let y = { (v: Double) in (1 - min(max(v, yLo), 1)) / (1 - yLo) * (h - 8) + 4 }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.profit.opacity(0.12))
                    .frame(width: max(2, x(sw.high) - x(sw.low)), height: h)
                    .offset(x: x(sw.low))
                Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1, height: h)
                    .offset(x: x(1))
                if yLo < 0 {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: w, height: 1).offset(y: y(0))
                }
                Path { p in
                    for (i, v) in ys.enumerated() {
                        let q = CGPoint(x: x(xs[i]), y: y(v))
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Circle().fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .position(x: x(c), y: y(sw.share(at: c)))
                Text(verbatim: "1×").font(.caption2).foregroundStyle(.secondary)
                    .position(x: x(1), y: h + 8)
                Text("甜点区").font(.caption2).foregroundStyle(Theme.profit)
                    .position(x: (x(sw.low) + x(sw.high)) / 2, y: h + 8)
            }
        }
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("押得越多,平均增长先升后降;押过了头,增长反而变少"))
    }

    @ViewBuilder
    private func sweetPill(_ c: Double, _ sw: Kelly.SweetSpot) -> some View {
        // ★ 说「保守 / 激进」,不说「低于 / 高于」—— 比甜点区小只是拿增长换回撤,不是错
        if c < sw.low - 0.005 {
            Pill(text: Loc.t("比甜点区保守"), tint: .secondary)
        } else if c > sw.high + 0.005 {
            Pill(text: Loc.t("比甜点区激进"), tint: Theme.alt)
        } else {
            Pill(text: Loc.t("在甜点区内"), tint: Theme.profit)
        }
    }

    // MARK: - 自选倍数

    private func custom(_ r: Kelly.Report, _ g: Kelly.RiskGrid) -> some View {
        let c = min(max(multiple, 0.05), 1)
        let f = c * r.fStar
        return VStack(alignment: .leading, spacing: 12) {
            Text("自选倍数").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: Self.times(c)).font(.title2.monospacedDigit().weight(.semibold))
                Text("凯利").foregroundStyle(.secondary)
                if let sw = r.sweet { sweetPill(c, sw) }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: budget > 0 ? Money.plain(budget * f) : "—")
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text(verbatim: String(format: Loc.t("每笔预算的 %@"), Self.pct1(f)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Slider(value: $multiple, in: 0.05...1, step: 0.01)
            Picker("期限", selection: $horizon) {
                ForEach(g.horizons, id: \.self) { h in Text("接下来 \(h) 笔").tag(h) }
            }
            .pickerStyle(.segmented)
            if let m = r.months(for: horizon) {
                Text(verbatim: String(format: Loc.t("按你到目前为止的交易频率,大约 %@ 个月。"), String(format: "%.1f", m)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let pt = g.at(c, horizon: horizon) {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("回撤超过").gridColumnAlignment(.leading)
                        ForEach(Kelly.RiskGrid.depths, id: \.self) { d in Text(verbatim: Self.pct(d)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    GridRow {
                        Text("的概率").font(.subheadline).gridColumnAlignment(.leading)
                        ForEach(Array(pt.pDrawdown.enumerated()), id: \.offset) { _, x in
                            Text(verbatim: Self.pct(x)).font(.body.monospacedDigit().weight(.semibold))
                                .foregroundStyle(x >= 0.5 ? Theme.loss : .primary)
                        }
                    }
                }
                Divider()
                stat(Text("回撤中位数"), Self.pct(pt.medianDrawdown))
                stat(Text("做完仍在亏"), Self.pct(pt.pLoss))
                stat(Text("长期增长速度"), String(format: Loc.t("满凯利的 %@"), Self.pct(r.growthShare(c))))
            }
        }
        .card()
    }

    private func stat(_ label: Text, _ value: String) -> some View {
        HStack {
            label.font(.subheadline)
            Spacer()
            Text(verbatim: value).font(.subheadline.monospacedDigit())
        }
    }

    // MARK: - 按回撤标准反查

    private func lookup(_ r: Kelly.Report, _ g: Kelly.RiskGrid) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按回撤标准反查").font(.headline)
            Text("回撤超过").font(.subheadline)
            Picker("回撤深度", selection: $ddDepth) {
                ForEach(Kelly.RiskGrid.depths, id: \.self) { d in Text(verbatim: Self.pct(d)).tag(d) }
            }
            .pickerStyle(.segmented)
            Text("的概率不超过").font(.subheadline)
            Picker("概率", selection: $ddProb) {
                ForEach([0.05, 0.1, 0.2], id: \.self) { x in Text(verbatim: Self.pct(x)).tag(x) }
            }
            .pickerStyle(.segmented)
            Text(verbatim: String(format: Loc.t("期限和上面一样:接下来 %lld 笔。"), horizon))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let c = g.maxMultiple(depth: ddDepth, prob: ddProb, horizon: horizon) {
                // ★ 往下取到 0.01:套用时不能比标准允许的再大一点
                let use = (c * 100).rounded(.down) / 100
                // ★ 括号里的金额放进句子里一起翻:拼在句子外面,英文会变成「per trade($501)」
                Group {
                    if budget > 0 {
                        Text(md: String(format: Loc.t("最多约 **%@ 凯利** —— 每笔预算的 **%@**(%@)。"),
                                        Self.times(use), Self.pct1(use * r.fStar),
                                        Money.plain(budget * use * r.fStar)))
                    } else {
                        Text(md: String(format: Loc.t("最多约 **%@ 凯利** —— 每笔预算的 **%@**。"),
                                        Self.times(use), Self.pct1(use * r.fStar)))
                    }
                }
                .font(.subheadline)
                if c >= 1 {
                    Text("满凯利也达得到这条标准 —— 但别忘了下面那条:满凯利这个数本身的误差很大。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { multiple = use } label: {
                    Label("用这个倍数", systemImage: "arrow.up.circle")
                }
                .disabled(abs(multiple - use) < 0.005)
            } else {
                Text(md: "**连 0.05× 凯利都达不到**这条标准 —— 按这段战绩,仓位再小也可能回撤这么深。")
                    .font(.subheadline)
            }
        }
        .card()
    }

    // MARK: - 这个数有多可靠

    private func reliability(_ r: Kelly.Report) -> some View {
        let lo = Self.pct(r.p5), hi = Self.pct(r.p95), mid = Self.pct(r.p50)
        let times = r.resamples.formatted()
        return VStack(alignment: .leading, spacing: 10) {
            Text("这个比例有多可靠").font(.headline)
            Text(md: String(format: Loc.t("把交易日整天整天地重抽 %@ 次、每次重算:90%% 落在 **%@ 到 %@** 之间,中间值 %@。"),
                            times, lo, hi, mid))
                .font(.subheadline)
            if r.pNoEdge >= 0.05 {
                Text(md: String(format: Loc.t("有 **%@** 的重抽里平均每笔 ≤ 0 —— 也就是这 %lld 个交易日还**证明不了有优势**。"),
                                Self.pct(r.pNoEdge), r.days))
                    .font(.subheadline)
            } else {
                Text(md: String(format: Loc.t("重抽里平均每笔 ≤ 0 的只有 %@。"), Self.pct(r.pNoEdge)))
                    .font(.subheadline)
            }
            if r.fStar > 0 {
                curve(r)
                let keep = Self.pct(Kelly.growth(r.fStar / 2, r.samples.map(\.r))
                                    / max(Kelly.growth(r.fStar, r.samples.map(\.r)), 1e-12))
                Text(md: String(format: Loc.t("曲线是平均每笔的复利增长:半凯利还留着 **%@** 的增长;押到两倍凯利附近,增长就变成负的 —— **押多了比押少了伤得重得多**。"),
                                keep))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    /// 增长 vs 仓位。★ 只画一条线 + 四个点(¼ / ½ / 满 / 2×),别的都是噪音。
    private func curve(_ r: Kelly.Report) -> some View {
        let xs = r.samples.map(\.r)
        let xMax = min(1, max(0.2, 2.3 * r.fStar))
        let pts = (0...80).map { i -> (Double, Double) in
            let f = xMax * Double(i) / 80
            return (f, Kelly.growth(f, xs))
        }
        let top = max(pts.map(\.1).max() ?? 0, 1e-9)
        let bottom = max(pts.map(\.1).min() ?? 0, -1.2 * top)
        let marks = [0.25, 0.5, 1, 2].filter { $0 * r.fStar <= xMax }
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height - 16
            let x = { (f: Double) in f / xMax * w }
            let y = { (g: Double) in (top - min(max(g, bottom), top)) / (top - bottom) * (h - 8) + 4 }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: w, height: 1)
                    .offset(y: y(0))
                Path { p in
                    for (i, pt) in pts.enumerated() {
                        let q = CGPoint(x: x(pt.0), y: y(pt.1))
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ForEach(marks, id: \.self) { m in
                    let f = m * r.fStar, g = Kelly.growth(f, xs)
                    Circle().fill(m == 1 ? Color.accentColor : Theme.card)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.6))
                        .frame(width: 9, height: 9)
                        .position(x: x(f), y: y(g))
                    markLabel(m).font(.caption2).foregroundStyle(.secondary)
                        .position(x: x(f), y: min(h + 8, y(g) + (g < 0 ? -12 : 14)))
                }
            }
        }
        .frame(height: 130)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("仓位越大,增长先升后跌"))
    }

    /// ★ 写成字面量:本地化守卫只认得出字面量(`Text(变量)` 它会当成不翻的运行时字符串)。
    @ViewBuilder
    private func markLabel(_ m: Double) -> some View {
        switch m {
        case 0.25: Text(verbatim: "¼")
        case 0.5:  Text(verbatim: "½")
        case 1:    Text("满")
        default:   Text(verbatim: "2×")
        }
    }

    // MARK: - 一笔归零

    private func ruin(_ r: Kelly.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("一笔归零会怎样").font(.headline)
            if r.wipeouts == 0 {
                Text(md: String(format: Loc.t("这 %lld 笔里最差一笔 %@,还**没有归零过**。0DTE 拿到收盘没走就是 −100%% —— 再多几笔那样的,满凯利会变成:"),
                                r.n, Money.pct(r.worst, decimals: 0)))
                    .font(.subheadline)
            } else {
                Text(md: String(format: Loc.t("这 %lld 笔里已经有 %lld 笔归零。再多几笔那样的,满凯利会变成:"),
                                r.n, r.wipeouts))
                    .font(.subheadline)
            }
            // ★ 四个标签一行放不下 —— 流式排,标签自己不许折行(折成两行就读不出来了)
            FlowLayout(spacing: 8) {
                Pill(text: Loc.t("现在") + " " + Self.pct(r.fStar), tint: .secondary).fixedSize()
                ForEach(Array(r.withRuin.enumerated()), id: \.offset) { i, f in
                    Pill(text: String(format: Loc.t("再多 %lld 笔 → %@"), i + 1, Self.pct(f)),
                         tint: Theme.alt)
                        .fixedSize()
                }
            }
        }
        .card()
    }

    // MARK: - 口径

    private func footnote(_ r: Kelly.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: String(format: Loc.t("算进来的:%lld 笔付权利金开仓的期权,%lld 个交易日。"), r.n, r.days))
            // ★ 只说有的那一类 —— 「卖方 0 笔」是噪音
            if r.excludedNonOption > 0 {
                Text(verbatim: String(format: Loc.t("没算进来:股票等 %lld 笔(风险尺度不同)。"), r.excludedNonOption))
            }
            if r.excludedCredit > 0 {
                Text(verbatim: String(format: Loc.t("没算进来:先收钱的卖方 %lld 笔(没有本金这个分母)。"), r.excludedCredit))
            }
            if let s = r.simple, r.avgLoss > 0 {
                Text(md: String(format: Loc.t("常见的简化公式「胜率 − 败率 ÷ 盈亏比」算出 %@,那是**每笔愿意亏掉的比例**,换成权利金是 %@ —— 它假设每笔亏损都正好等于平均值。"),
                                Self.pct(s), Self.pct(s / r.avgLoss)))
            }
            Text("回撤都是模拟:先按交易日重抽一份可能的真实战绩,再从里面连抽 100 或 250 笔。")
            Text("书上常见的回撤公式 (1−d)^(2/c−1) 假设优势是确定的、没有极端亏损 —— 套在这段战绩上会把回撤风险低估很多,所以这里用模拟。")
            Text("这是把公式套在你过去的战绩上算出来的,不是建议;模拟假设以后和过去这段时间一样 —— 这是偏乐观的假设。")
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    private func notEnough(_ r: Kelly.Report) -> some View {
        Text(verbatim: String(format: Loc.t("才 %lld 笔付权利金开仓的期权(%lld 个交易日)。凯利对样本极其敏感 —— 攒到 %lld 笔、%lld 个交易日再看。"),
                    r.n, r.days, Kelly.minTrades, Kelly.minDays))
            .font(.subheadline).foregroundStyle(.secondary)
            .card()
    }

    /// `0.25×`
    static func times(_ c: Double) -> String { String(format: "%.2f×", c) }
    /// `8.4%` —— 每笔占预算这种要看清小数的地方。
    static func pct1(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

    /// `33%`;不到 1% 的留一位小数,免得 0.9% 被写成 1%。
    static func pct(_ x: Double) -> String {
        x > 0 && x < 0.01 ? String(format: "%.1f%%", x * 100) : String(format: "%.0f%%", x * 100)
    }
}
