import SwiftUI

/// **按开仓时间看盈亏。**
///
/// ★ 用户 2026-10-03:「分析下我最赚钱的时间段」→「做进 app 里」。
///
/// ★★ 这一节最重要的不是图,是**那几句结论**。表上的高低大部分是噪声 ——
///   那天的真实数据,七段之间的差别和随机分组差不多大。
///   所以:图照画、表照列,但结论只说**算过之后站得住的**,
///   并且把「这段主要靠一笔」「这几笔时间是假的、没算进来」都说出来。
struct TimeOfDaySection: View {
    let trades: [Trade]
    var onPick: (Trade) -> Void

    var body: some View {
        let r = TimeOfDay.report(trades)
        VStack(alignment: .leading, spacing: 14) {
            Text("按开仓时间").font(.headline)

            if r.n == 0 {
                Text("没有开仓时间可用的交易。").font(.footnote).foregroundStyle(.secondary)
            } else {
                dots(r)
                rows(r)
                verdict(r)
            }
            excludedNote(r)
        }
    }

    // MARK: - 每一笔一个点

    private let lo = 570.0, hi = 960.0     // 9:30 – 16:00

    private func dots(_ r: TimeOfDay.Report) -> some View {
        let maxAbs = max(1, r.points.map { abs($0.pnl) }.max() ?? 1)
        let flagged = Set(r.extremes.map(\.slotID))
        return VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let xOf = { (m: Double) in (m - lo) / (hi - lo) * w }
                let yOf = { (p: Double) in h / 2 - p / maxAbs * (h / 2 - 6) }
                ZStack(alignment: .topLeading) {
                    // 过了门槛的那一段,铺一层浅底 —— 只有算过站得住的才铺
                    ForEach(r.slots.filter { flagged.contains($0.id) }) { s in
                        Rectangle().fill(Theme.alt.opacity(0.10))
                            .frame(width: xOf(Double(s.end)) - xOf(Double(s.start)), height: h)
                            .offset(x: xOf(Double(s.start)))
                    }
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: w, height: 1)
                        .offset(y: h / 2)
                    ForEach(Array(r.points.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(Theme.pnl(pt.pnl == 0 ? 1 : pt.pnl))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.2))
                            .position(x: xOf(Double(pt.minute)), y: yOf(pt.pnl))
                            .onTapGesture { onPick(pt.trade) }
                    }
                }
            }
            .frame(height: 150)
            // 横轴:整点
            GeometryReader { geo in
                ForEach([570, 660, 780, 900, 960], id: \.self) { m in
                    Text(verbatim: String(format: "%d:%02d", m / 60, m % 60))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: (Double(m) - lo) / (hi - lo) * geo.size.width, y: 6)
                }
            }
            .frame(height: 14)
        }
    }

    // MARK: - 每一段一行

    private func rows(_ r: TimeOfDay.Report) -> some View {
        let flagged = Set(r.extremes.map(\.slotID))
        return VStack(spacing: 0) {
            ForEach(r.slots) { s in
                HStack(spacing: 8) {
                    Text(verbatim: s.label).font(.subheadline.monospacedDigit())
                        .frame(width: 48, alignment: .leading)
                    Text(verbatim: String(format: Loc.t("%lld 笔"), s.trades.count))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    if s.hingesOnOneTrade {
                        // ★ 看着是好(或坏)时段,其实是一笔单子
                        Pill(text: Loc.t("主要靠一笔"), tint: .secondary)
                    }
                    if flagged.contains(s.id) {
                        Image(systemName: "exclamationmark.circle").font(.caption)
                            .foregroundStyle(Theme.alt)
                    }
                    Spacer(minLength: 4)
                    if s.trades.isEmpty {
                        Text(verbatim: "—").foregroundStyle(.tertiary)
                    } else {
                        if let w = s.summary.winRate {
                            Text(verbatim: "\(Int((w * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(verbatim: Money.signed(s.summary.total))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.pnl(s.summary.total))
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                }
                .padding(.vertical, 7)
                if s.id < r.slots.count - 1 { Divider() }
            }
        }
        .card(padding: 12)
    }

    // MARK: - 结论:只说站得住的

    @ViewBuilder
    private func verdict(_ r: TimeOfDay.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = r.pOverall {
                if p >= 0.05 {
                    Text(md: String(format: Loc.t(
                        "**时段之间的差别,和随机分组差不多大**(p = %@)—— 上面的高低大部分是巧合,别当成规律。"),
                        Self.pString(p)))
                } else {
                    Text(md: String(format: Loc.t(
                        "时段之间的差别**不太像巧合**(p = %@)。"), Self.pString(p)))
                }
            } else {
                Text(verbatim: String(format: Loc.t(
                    "才 %lld 笔有开仓时间,还看不出时段规律 —— 攒到 %lld 笔再看。"),
                    r.n, TimeOfDay.minForTest))
            }
            ForEach(Array(r.extremes.enumerated()), id: \.offset) { _, e in
                let label = r.slots[e.slotID].label
                Label {
                    switch e.kind {
                    case .cappedUpside:
                        Text(md: String(format: Loc.t(
                            "**%1$@ 这一段 %2$lld 笔,最好的一笔只有 %3$@** —— 随便挑 %2$lld 笔都这么小的概率 %4$@。这一段从来没赚到过大钱。"),
                            label, e.n, Money.signed(e.value), Self.pctString(e.p)))
                    case .cappedDownside:
                        Text(md: String(format: Loc.t(
                            "**%1$@ 这一段 %2$lld 笔,最差的一笔也只有 %3$@** —— 随便挑 %2$lld 笔都这么轻的概率 %4$@。这一段从来没亏过大钱。"),
                            label, e.n, Money.signed(e.value), Self.pctString(e.p)))
                    }
                } icon: {
                    Image(systemName: e.kind == .cappedUpside ? "arrow.down.to.line" : "arrow.up.to.line")
                        .foregroundStyle(e.kind == .cappedUpside ? Theme.alt : Theme.profit)
                }
            }
            if r.pOverall != nil {
                // ★ 门槛按检验次数收紧 —— 7 段 × 两头,随便看总能看出点什么
                Text(verbatim: String(format: Loc.t(
                    "只列算过之后站得住的:每段的最好和最差一笔都检验了,门槛按检验次数收紧到 %@。"),
                    Self.pctString(r.threshold)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.footnote)
    }

    // MARK: - 没算进来的,说清楚为什么

    @ViewBuilder
    private func excludedNote(_ r: TimeOfDay.Report) -> some View {
        let parts: [String] = [
            r.excludedPlaceholder > 0 ? String(format: Loc.t(
                "%lld 笔开仓时间正好 11:00,是旧版本没认出时间时填的(在复盘页改成真实时间就会算进来)"),
                r.excludedPlaceholder) : nil,
            r.excludedEstimated > 0 ? String(format: Loc.t("%lld 笔开仓时间是估的"), r.excludedEstimated) : nil,
            r.outsideHours > 0 ? String(format: Loc.t("%lld 笔在盘前或盘后开仓"), r.outsideHours) : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(verbatim: Loc.t("没算进来:") + parts.joined(separator: ";") + "。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// ★ 0.1 以下给三位:门槛 0.05 附近写成「0.05」分不出是 0.049 还是 0.051(持仓时间那一节当场碰上了)
    static func pString(_ p: Double) -> String { p < 0.1 ? String(format: "%.3f", p) : String(format: "%.2f", p) }
    static func pctString(_ p: Double) -> String { p < 0.01 ? String(format: "%.2f%%", p * 100) : String(format: "%.1f%%", p * 100) }
}
