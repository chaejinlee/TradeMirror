import SwiftUI

/// 战绩热力图 —— **一天一个小方格**,点进去看那天的具体交易。
///
/// ★ 用户 2026-09-03:「主页历史战绩能做到像是那种一个个小方格的类型,
///   然后点进去能查看具体信息」。
///
/// ★★ 一条自我约束:**没交易的日子和盈亏为 0 的日子,颜色必须不一样。**
///   这个 App 反复守的就是这条 —— 不知道就说不知道,没发生就别画成发生过。
struct HeatmapView: View {
    let trades: [Trade]
    /// 点某一天时回调(交给外面去弹那天的清单)。
    var onPick: (HeatmapCell) -> Void

    /// 往回排几周。★ 14 周 ≈ 一个季度,刚好一屏排得下。
    private let weeks = 14

    private var stats: PeriodStats { PeriodStats.compute(trades, period: .day) }
    private var grid: [[HeatmapCell]] { Heatmap.grid(buckets: stats.buckets, weeks: weeks) }

    var body: some View {
        let g = grid
        let maxAbs = Heatmap.maxAbsPnL(g)
        let s = Heatmap.summary(g)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近 \(weeks) 周").font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if s.days > 0 {
                    Text(verbatim: String(format: Loc.t("%1$lld 个交易日 · 绿 %2$lld"),
                                          s.days, s.greenDays))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .top, spacing: 3) {
                // 行标:只标周一/三/五,五行全标会挤成一团
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(1...5, id: \.self) { d in
                        Text(weekdayLabel(d))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                            .frame(height: 22)
                    }
                }
                .frame(width: 14)

                // ★★ 要在格子里写金额,格子就得有宽度 ——
                //   14 周挤在一屏里每格只有 22pt,数字塞不下。
                //   ⇒ 格子**固定 38pt 宽**,整条横向滚动,**默认停在最右(最近)**。
                //   <b>既不砍历史,也不把数字挤没。</b>
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(Array(g.enumerated()), id: \.offset) { wi, week in
                                VStack(spacing: 3) {
                                    ForEach(week) { cell in
                                        HeatCell(cell: cell, maxAbs: maxAbs,
                                                 side: 38, height: 22)
                                            // ★ 只有真有交易的那天能点开 ——
                                            //   `buckets` 里永远含「今天」那一格(哪怕 n=0),
                                            //   照着 `bucket != nil` 判会给出**空的**入口。
                                            .onTapGesture {
                                                if cell.hasRealizedPnL
                                                    || (cell.bucket?.openCount ?? 0) > 0 {
                                                    onPick(cell)
                                                }
                                            }
                                    }
                                }
                                .frame(width: 38)
                                .id(wi)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(g.count - 1, anchor: .trailing) }
                }
                .frame(height: 22 * 5 + 3 * 4)
            }

            // ★ 图例三种视图共用一份 —— 抄两份就会出现「日的说法和月的说法不一样」
            HeatLegend(pnl: s.pnl, showDays: s.days > 0)

            // ★ 原来这里常驻一行 9pt 灰字解释格子怎么读 —— 收进了战绩卡片右上角的 ⓘ。
        }
    }

    private func weekdayLabel(_ d: Int) -> LocalizedStringKey {
        switch d {
        case 1:  return "一"
        case 3:  return "三"
        case 5:  return "五"
        default: return ""
        }
    }
}

struct HeatCell: View {
    let cell: HeatmapCell
    let maxAbs: Double
    let side: CGFloat
    /// 「日」是 15,周/月/年的格子高一点(它们少,占得起)。
    var height: CGFloat = 15

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(fill)
            .frame(maxWidth: side, minHeight: height, maxHeight: height)
            .overlay {
                // ★★ 用户 2026-09-03:「在小格子里显示盈亏金额」。
                //   ⚠️ 塞得下才写 —— 写不下的数字等于没写,还会把颜色挡住。
                //   颜色深的时候用白字,浅的时候用本色:<b>对比度不能靠运气。</b>
                if let n = cell.compactPnL {
                    Text(verbatim: n)
                        .font(.system(size: numberSize, weight: .semibold,
                                      design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(numberColor)
                        .padding(.horizontal, 1)
                }
            }
            .overlay {
                // 只有未平仓的那天:描个边,不染色 —— 持仓成本不是盈亏
                if !cell.hasRealizedPnL, (cell.bucket?.openCount ?? 0) > 0 {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.open.opacity(0.8), lineWidth: 1)
                }
                // ★★ 今天永远有个圈。用户 2026-09-03:「今天的也没显示」——
                //   当天只赚了 $100、而当期最大是 $261,连续映射算出 0.38,
                //   <b>淡到和空格分不出来</b>。一张找不到「今天在哪」的日历不叫日历。
                if cell.isToday {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                }
            }
            .opacity(cell.isFuture ? 0.35 : 1)
    }

    /// 数字多大。★ 格子矮的时候(日视图)小一号,别顶着边。
    private var numberSize: CGFloat { height >= 24 ? 11 : 9 }

    /// 深底白字、浅底本色 —— **对比度不能靠运气**。
    private var numberColor: Color {
        guard let b = cell.bucket, cell.hasRealizedPnL else { return .secondary }
        let i = Heatmap.intensity(b.pnl, maxAbs: maxAbs)
        if i >= 0.6 { return .white }
        return Theme.pnl(b.pnl)
    }

    private var fill: Color {
        // ★ 空格要**退到背景里** —— 原来 `secondary.opacity(0.12)` 在 70 格里压着 11 格有颜色的
        guard let b = cell.bucket else { return Theme.emptyCell }  // 没交易
        guard cell.hasRealizedPnL else {
            // ★★ 那天开了仓、还没平。原来只描 1px 边、不填色 ——
            //   加了一笔还没平的单之后那一格几乎看不出变化,
            //   读起来就是<b>「加了单但小方格没更新」</b>(用户 2026-09-03 的原话)。
            //   ⇒ 填一层琥珀色:**看得见「那天有事发生」,又不冒充盈亏**。
            return b.openCount > 0 ? Theme.open.opacity(0.3) : Theme.emptyCell
        }
        let i = Heatmap.intensity(b.pnl, maxAbs: maxAbs)
        return Theme.pnl(b.pnl).opacity(i)
    }
}

/// 周 / 月 / 年的小格子。
///
/// ★ 用户 2026-09-03:「把周月年也能做成小格子」。
/// ★★ 和「日」刻意长得不一样:周/月/年**本来就是一维的**,
///   摆成日历只会凭空多出一堆不存在的格子。所以这里是**带标签的一排排方块**,
///   每一格底下写清是哪一周/哪个月/哪一年 —— <b>一个没有标签的方块等于没有信息。</b>
struct PeriodSquaresView: View {
    let trades: [Trade]
    let period: StatsPeriod
    var onPick: (HeatmapCell) -> Void

    /// 往回排几格 + 一行几个。★ 数量按「这个周期看多久才有意义」定,不是拍脑袋:
    ///   周看半年、月看两年、年看五年。
    private var config: (count: Int, perRow: Int) {
        switch period {
        case .week:  return (26, 13)
        // ★ 12 个月而不是 24:标签只有「10 月」没有年份,
        //   24 个月里「10 月」会出现两次 —— <b>两个格子长得一样却不是同一件事</b>。
        //   12 个月的窗口里每个月只出现一次,不会认错。
        case .month: return (12, 6)
        default:     return (5, 5)
        }
    }

    private var cells: [HeatmapCell] {
        Heatmap.cells(buckets: PeriodStats.compute(trades, period: period).buckets,
                      period: period, count: config.count)
    }

    var body: some View {
        let cs = cells
        let maxAbs = Heatmap.maxAbsPnL(cs)
        let s = Heatmap.summary(cs)
        let rows = stride(from: 0, to: cs.count, by: config.perRow).map {
            Array(cs[$0..<min($0 + config.perRow, cs.count)])
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if s.days > 0 {
                    Text(verbatim: String(format: Loc.t("%1$lld 格有交易 · 绿 %2$lld"),
                                          s.days, s.greenDays))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        ForEach(row) { cell in
                            VStack(spacing: 2) {
                                HeatCell(cell: cell, maxAbs: maxAbs, side: .infinity,
                                         height: period == .year ? 34 : 26)
                                Text(verbatim: cell.shortLabel)
                                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if cell.hasRealizedPnL || (cell.bucket?.openCount ?? 0) > 0 {
                                    onPick(cell)
                                }
                            }
                        }
                        // 最后一行不满时补空位,免得格子被拉宽
                        if row.count < config.perRow {
                            ForEach(0..<(config.perRow - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }

            HeatLegend(pnl: s.pnl, showDays: s.days > 0)
            // ★ `Text(md: "…\(变量)…")` 的 key 里带着插值,运行时永远查不到 ——
            //   和「本%@还没交易」同一个病。句子**各给各的 key**。
            Text(md: footnote).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private var headline: LocalizedStringKey {
        switch period {
        case .week:  return "最近 26 周"
        case .month: return "最近 12 个月"
        default:     return "最近 5 年"
        }
    }
    private var footnote: String {
        switch period {
        case .week:  return Loc.t("点一格看那一周的交易。**空格 = 那一周没交易**,不是持平。")
        case .month: return Loc.t("点一格看那个月的交易。**空格 = 那个月没交易**,不是持平。")
        default:     return Loc.t("点一格看那一年的交易。**空格 = 那一年没交易**,不是持平。")
        }
    }
}

/// 图例。★ 三种视图共用一份 —— 抄两份就会出现「日的图例和月的图例说法不一样」。
struct HeatLegend: View {
    let pnl: Double
    var showDays: Bool = true

    var body: some View {
        // ★ 原来一行里挤了 9 个色块 + 4 个 9pt 小字(亏/盈/未平/现在)。
        //   「未平」「现在」是什么意思已经收进战绩卡片的 ⓘ,这里只留色阶。
        HStack(spacing: 4) {
            Text("亏").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            ForEach([1.0, 0.6, 0.42], id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Theme.loss.opacity(i)).frame(width: 10, height: 10)
            }
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Theme.emptyCell).frame(width: 10, height: 10)
            ForEach([0.42, 0.6, 1.0], id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Theme.profit.opacity(i)).frame(width: 10, height: 10)
            }
            Text("盈").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
            if showDays {
                Text(verbatim: Money.signed(pnl))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.pnl(pnl))
            }
        }
    }
}

/// 点开某一格:那一段做了什么。
struct DayDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let cell: HeatmapCell
    let trades: [Trade]
    /// 这一格是哪个周期的。★ 取交易时必须用**同一个周期**,
    ///   否则「点开某个月」会按天去筛,拿回来一个空清单。
    var period: StatsPeriod = .day
    var onOpen: (Trade) -> Void

    private var dayTrades: [Trade] {
        guard let b = cell.bucket else { return [] }
        return PeriodStats.trades(trades, in: b, period: period)
            .sorted { ($0.entryTime ?? .distantPast) < ($1.entryTime ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let b = cell.bucket, b.n > 0 {
                        LabeledContent("这一格的盈亏") {
                            Text(verbatim: Money.signed(b.pnl))
                                .fontWeight(.semibold).monospacedDigit()
                                .foregroundStyle(Theme.pnl(b.pnl))
                        }
                        LabeledContent("平了几笔") {
                            Text(verbatim: String(format: Loc.t("%1$lld 笔 · 赢 %2$lld"),
                                                  b.n, b.wins))
                        }
                    }
                    if let b = cell.bucket, b.openCount > 0 {
                        LabeledContent("这一格里开了还没平") {
                            Text(verbatim: "\(b.openCount)").foregroundStyle(Theme.open)
                        }
                    }
                } header: {
                    Text(verbatim: cell.label)
                }

                Section {
                    ForEach(dayTrades) { t in
                        Button { onOpen(t); dismiss() } label: {
                            TradeRow(trade: t).foregroundStyle(Color.primary)
                        }
                    }
                    if dayTrades.isEmpty {
                        Text("这一格里没有交易").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("这一格里的交易")
                } footer: {
                    // ★ 口径要写清楚,否则「为什么这笔算在这天」永远说不明白
                    Text(md: "已平仓的按**盈亏兑现那天**归期,未平仓的按**开仓那天** —— 和主页大数字同一个口径。")
                }
            }
            .navigationTitle(Text(verbatim: cell.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            } }
        }
    }
}
