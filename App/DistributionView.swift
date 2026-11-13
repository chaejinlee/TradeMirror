import SwiftUI

/// **单笔盈亏的分布** —— 一格一笔的直方图。
///
/// ★ 用户 2026-09-18:「有没有办法做成可视化的直方图」。
///
/// ★★ 为什么是「一格一笔」而不是实心柱子:
///   他现在总共二十几笔,普通直方图只剩五六根柱子,<b>看不出任何东西</b>。
///   拆成一格一笔,同一张图既能看出形状,又能看见每一笔 —— 而且点得进去。
///   等笔数多起来(几百笔),格子会自动变薄,那时它自然就退化成实心柱子。
struct DistributionView: View {
    @Environment(\.dismiss) private var dismiss
    let trades: [Trade]
    /// 点某一格 → 打开那一笔。
    var onPick: (Trade) -> Void

    /// 只看某一类加仓次数。nil = 全部。
    @State private var addsFilter: Distribution.AddsBucket?
    /// 只看某个出场原因。nil = 全部(`.some(nil)` = 只看没填的)。
    @State private var reasonFilter: String??

    private var shown: [Trade] {
        var xs = Distribution.eligible(trades)
        if let a = addsFilter {
            xs = xs.filter { Distribution.AddsBucket.of(Distribution.addCount($0)) == a }
        }
        if let r = reasonFilter {
            xs = xs.filter { ($0.exitReason?.isEmpty == false ? $0.exitReason : nil) == r }
        }
        return xs
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if Distribution.eligible(trades).isEmpty {
                        ContentUnavailableView {
                            Label("还没有已平仓的交易", systemImage: "chart.bar")
                        } description: {
                            // ★ `Text(String)` 不认 markdown,星号会原样显示 —— 守卫在这儿逮到过
                            Text(md: "分布要的是**已实现**的盈亏 —— 未平仓的那几笔算不出来,所以不在这张图里。")
                        }
                        .padding(.top, 40)
                    } else {
                        summaryRow
                        chart
                        filters
                        insight
                        // ★ 用户 2026-10-03:「分析下我最赚钱的时间段」→「做进 app 里」。
                        //   跟着上面的筛选走:筛了「加仓 ≥3 次」,这里也只看那几笔。
                        Divider().padding(.vertical, 4)
                        TimeOfDaySection(trades: shown, onPick: onPick)
                        // ★ 用户 2026-10-06:「增加持仓时间功能」。同样跟着上面的筛选走。
                        Divider().padding(.vertical, 4)
                        HoldingTimeSection(trades: shown, onPick: onPick)
                    }
                }
                .padding()
            }
            .navigationTitle("盈亏分布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    // MARK: - 上面那排数

    private var summaryRow: some View {
        let s = Distribution.summary(shown)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: Money.signed(s.total))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.pnl(s.total))
                Text(verbatim: String(format: Loc.t("%1$lld 笔已平 · 胜率 %2$@"), s.n,
                                      s.winRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            // ★★ 两行并排摆:**金额问「一笔赚多少」,百分比问「一块钱赚多少」。**
            //   用户 2026-09-22 要的是第二行。两行会给出不同的结论 ——
            //   他那 23 笔金额口径 0.68、百分比口径 0.78 —— <b>那不是矛盾,是两个问题</b>,
            //   所以必须并排摆,不能只留一行让人以为那就是全部。
            // ★ 2026-10-05 再加中位数(用户:「添加获胜金额、获胜百分比的中位数」)。
            //   平均会被一两笔大单拉走 —— 那天 58 笔:平均盈 $258,中位盈只有 $122。
            //   平均和中位**挨着摆**:差得越远,越说明是靠少数几笔大单撑着。
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text(verbatim: "").font(.caption2)
                    head(Loc.t("盈")); head(Loc.t("亏")); head(Loc.t("盈亏比"))
                }
                GridRow {
                    rowLabel(Loc.t("平均金额"))
                    num(s.avgWin.map { money($0) }, up: true)
                    num(s.avgLoss.map { money($0) }, up: false)
                    num(s.payoffRatio.map { String(format: "%.2f", $0) })
                }
                GridRow {
                    rowLabel(Loc.t("中位金额"))
                    num(s.medianWin.map { money($0) }, up: true)
                    num(s.medianLoss.map { money($0) }, up: false)
                    num(s.medianPayoffRatio.map { String(format: "%.2f", $0) })
                }
                Divider().gridCellColumns(4)
                GridRow {
                    rowLabel(Loc.t("平均百分比"))
                    num(s.avgWinPct.map { pct($0) }, up: true)
                    num(s.avgLossPct.map { pct($0) }, up: false)
                    num(s.payoffRatioPct.map { String(format: "%.2f", $0) })
                }
                GridRow {
                    rowLabel(Loc.t("中位百分比"))
                    num(s.medianWinPct.map { pct($0) }, up: true)
                    num(s.medianLossPct.map { pct($0) }, up: false)
                    num(s.medianPayoffRatioPct.map { String(format: "%.2f", $0) })
                }
            }

            // ★ 有笔数算不出百分比时**必须说** —— 否则「平均 +49%」会被当成全部的平均
            if !s.pctCoversEveryTrade {
                let missing = (s.wins - s.winsWithPct) + (s.losses - s.lossesWithPct)
                Text(verbatim: String(format: Loc.t(
                    "★ 其中 %lld 笔算不出百分比(贷记开仓没有可信的分母),没进上面那一行的平均。"),
                                      missing))
                    .font(.caption2).foregroundStyle(Theme.warn)
            }
        }
    }

    private func head(_ t: String) -> some View {
        Text(verbatim: t).font(.caption2).foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
    private func rowLabel(_ t: String) -> some View {
        Text(verbatim: t).font(.caption).foregroundStyle(.secondary)
    }
    /// ★ 算不出来就写「—」,不写 0 —— 这个 App 反复守的那条。
    private func num(_ v: String?, up: Bool? = nil) -> some View {
        Text(verbatim: v ?? "—")
            .font(.subheadline.weight(.medium)).monospacedDigit()
            .foregroundStyle(v == nil ? AnyShapeStyle(.tertiary)
                             : AnyShapeStyle(up == nil ? Color.primary
                                             : (up! ? Theme.profit : Theme.loss)))
            .gridColumnAlignment(.trailing)
    }

    /// `0.489` → `+49%`。★ 负号用 U+2212,和金额那一行对齐。
    private func pct(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return (n > 0 ? "+" : (n < 0 ? "−" : "")) + String(abs(n)) + "%"
    }

    private func money(_ v: Double) -> String {
        (v < 0 ? "−" : "") + "$" + String(Int(abs(v).rounded()))
    }

    // MARK: - 图

    private var chart: some View {
        let bins = Distribution.bins(shown)
        let maxN = max(1, bins.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let bw = geo.size.width / CGFloat(max(1, bins.count))
                // ★★ 格子宽度**必须封顶**。档数少的时候 `bw` 能到 47pt,
                //   画出来是几个大色块,完全不像一张图(实测就是这样)。
                //   规范:柱子 ≤24pt。宽度不够时再让它缩,但缩到 3pt 为止。
                let cw = max(3, min(24, bw - 4))
                let ch = max(4, min(22, (geo.size.height - 2) / CGFloat(maxN)) - 2)
                ZStack(alignment: .bottomLeading) {
                    // 0 的位置画一条虚线 —— 这是整张图唯一需要标出来的刻度
                    if let zi = bins.firstIndex(where: { $0.lo == 0 }) {
                        Rectangle().fill(.tertiary).frame(width: 1)
                            .offset(x: CGFloat(zi) * bw)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(bins) { b in
                            VStack(spacing: 2) {
                                Spacer(minLength: 0)
                                ForEach(b.trades.reversed(), id: \.id) { t in
                                    cell(t, width: cw, height: ch)
                                }
                            }
                            .frame(width: bw)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: max(60, min(240, CGFloat(maxN) * 24 + 8)))

            axis(bins)
        }
    }

    private func cell(_ t: Trade, width: CGFloat, height: CGFloat) -> some View {
        let p = t.displayablePnL ?? 0
        let deep = Distribution.addCount(t) >= 3
        return RoundedRectangle(cornerRadius: 3)
            // ★ 2026-09-24:原来盈利用蓝色(当时为色弱单独挑的)—— 可全 App 都是绿涨红跌,
            //   只有这一页是蓝的,读起来像换了一套语言。色弱靠的是格子在 0 左还是右。
            .fill(Theme.pnl(p == 0 ? 1 : p))
            .frame(width: width, height: height)
            // ★ 深度加仓的描个边 —— 不用颜色区分,颜色已经被盈亏占了
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(deep ? 0.85 : 0), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { onPick(t) }
            .accessibilityLabel(Text(verbatim:
                "\(t.symbol) \(money(p))\(deep ? Loc.t(",深度加仓") : "")"))
    }

    /// 横轴:**只标三个** —— 左端、0、右端。
    ///
    /// ★★ 第一版给每一档都留了位置再 `fixedSize`,结果三个标签叠成了
    ///   `−$10000$400`(实测截图)。<b>格子才二十来点宽,横轴根本放不下每档一个数。</b>
    private func axis(_ bins: [DistributionBin]) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: money(bins.first?.lo ?? 0))
            Spacer(minLength: 0)
            if bins.contains(where: { $0.lo == 0 }) {
                Text(verbatim: "0").fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            Text(verbatim: money(bins.last?.hi ?? 0))
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        .lineLimit(1)
    }

    // MARK: - 筛选

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按加仓次数看").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(Loc.t("全部"), on: addsFilter == nil) { addsFilter = nil }
                    ForEach(Distribution.byAdds(trades), id: \.0) { b, g in
                        let sum = Distribution.summary(g).total
                        chip("\(b.label { Loc.t($0) }) · \(g.count)",
                             on: addsFilter == b, tint: Theme.pnl(sum == 0 ? 1 : sum)) {
                            addsFilter = addsFilter == b ? nil : b
                        }
                    }
                }
            }
            Text("按出场原因看").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(Loc.t("全部"), on: reasonFilter == nil) { reasonFilter = nil }
                    ForEach(Distribution.byExitReason(trades), id: \.0) { r, g in
                        let sum = Distribution.summary(g).total
                        // ★ 没填的单独一档,**不并进「其他」** —— 那是两件事
                        chip("\(r.map { Loc.t($0) } ?? Loc.t("没填原因")) · \(g.count)",
                             on: reasonFilter == .some(r), tint: Theme.pnl(sum == 0 ? 1 : sum)) {
                            reasonFilter = reasonFilter == .some(r) ? nil : .some(r)
                        }
                    }
                }
            }
        }
    }

    private func chip(_ text: String, on: Bool, tint: Color = .accentColor,
                      tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(verbatim: text)
                .font(.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? tint.opacity(0.18) : Color(.secondarySystemFill),
                            in: Capsule())
                .foregroundStyle(on ? tint : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 一句话

    /// ★★ 这一段是这页存在的理由。图只给形状,**结论要写出来**。
    ///   而且只在**站得住**的时候写:样本太少就说样本太少。
    @ViewBuilder
    private var insight: some View {
        let s = Distribution.summary(Distribution.eligible(trades))
        VStack(alignment: .leading, spacing: 10) {
            if s.n < 10 {
                Text(md: "★ 才 **\(s.n) 笔**,形状还说明不了什么 —— 攒到二三十笔再看这张图。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let w = s.avgWin, let l = s.avgLoss, let r = s.payoffRatio,
                      let wr = s.winRate {
                // ★★ 格式化**必须提到插值外面**:`\(String(format: "%.2f", r))` 里那对引号
                //   会被本地化提取器当成字符串结尾,key 从那里被截断 ⇒ 永远查不到译文。
                //   <b>守卫报的「未翻」是真的,只是原因不在译文,在写法。</b>
                let ratio = String(format: "%.2f", r)
                let pct = Int((wr * 100).rounded())
                if r < 1 && wr > 0.5 {
                    Text(md: "**赢的次数多,但每次赢得少。** 胜率 \(pct)%,可平均赚 \(money(w)) / 平均亏 \(money(l)) —— 盈亏比 \(ratio)。\n★ 图上右边很密、左边很长,就是这个意思。")
                        .font(.footnote)
                } else if r >= 1 && wr <= 0.5 {
                    Text(md: "**赢的次数少,但每次赢得多。** 胜率 \(pct)%,盈亏比 \(ratio) —— 这是靠少数几笔撑起来的形状。")
                        .font(.footnote)
                }
            }

            // ★ 深度加仓那一档:只在它**真的能改变结论**时才说
            let deep = Distribution.byAdds(trades).first { $0.0 == .many }?.1 ?? []
            if !deep.isEmpty {
                let d = Distribution.summary(deep).total
                let rest = s.total - d
                if d < 0 && rest > 0 {
                    Text(md: "★★ **加仓 ≥3 次**的那 \(deep.count) 笔合计 \(money(d))。\n去掉它们,其余 \(s.n - deep.count) 笔是 **\(money(rest))** —— 这 \(deep.count) 笔吃掉的比你全部净利润还多。")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.loss.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Text("点任意一格 = 打开那一笔。描了边的格子是加仓 ≥3 次的。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
