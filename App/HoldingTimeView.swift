import SwiftUI

/// **按持仓时间看盈亏。**
///
/// ★ 用户 2026-10-06:「增加持仓时间功能」。
///
/// ★★ 和按开仓时间那一节同一个规矩:图照画、表照列,结论只说**算过之后站得住的**。
///   他那 60 笔里站得住的是「亏单比赢单拿得久」(中位 20 分钟 vs 8 分钟,p ≈ 1%);
///   「拿得越久越亏」这种整体趋势反而说不准 —— 也照实说。算法在引擎 `HoldingTime` 里(有测试)。
struct HoldingTimeSection: View {
    let trades: [Trade]
    var onPick: (Trade) -> Void

    var body: some View {
        let r = HoldingTime.report(trades)
        VStack(alignment: .leading, spacing: 14) {
            Text("按持仓时间").font(.headline)
            if r.n == 0 {
                Text("没有开平仓时间都知道的交易。").font(.footnote).foregroundStyle(.secondary)
            } else {
                dots(r)
                rows(r)
                verdict(r)
            }
            excludedNote(r)
        }
    }

    // MARK: - 每一笔一个点(横轴是对数刻度:1 分钟和 2 分钟的差别,比 1 小时和 1 小时 1 分钟大得多)

    private let lo = log10(0.5), hi = log10(2.0 * 1440)      // 半分钟 … 两天
    private func x(_ seconds: TimeInterval, _ w: CGFloat) -> CGFloat {
        let m = max(seconds / 60, 0.5)
        return CGFloat((min(log10(m), hi) - lo) / (hi - lo)) * w
    }

    private func dots(_ r: HoldingTime.Report) -> some View {
        let maxAbs = max(1, r.points.map { abs($0.pnl) }.max() ?? 1)
        return VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let yOf = { (p: Double) in h / 2 - p / maxAbs * (h / 2 - 6) }
                ZStack(alignment: .topLeading) {
                    // 分段的边界(2、5、15、30、60 分钟),淡淡一条
                    ForEach(HoldingTime.edges, id: \.self) { e in
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1, height: h)
                            .offset(x: x(e, w))
                    }
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: w, height: 1)
                        .offset(y: h / 2)
                    ForEach(Array(r.points.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(Theme.pnl(pt.pnl == 0 ? 1 : pt.pnl))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 1.2))
                            .position(x: x(pt.seconds, w), y: yOf(pt.pnl))
                            .onTapGesture { onPick(pt.trade) }
                    }
                }
            }
            .frame(height: 150)
            GeometryReader { geo in
                ForEach([60.0, 300, 900, 3600, 86400], id: \.self) { s in
                    Text(verbatim: HoldingTime.format(s, Loc.t))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: x(s, geo.size.width), y: 6)
                }
            }
            .frame(height: 14)
        }
    }

    // MARK: - 每一段一行

    private func rows(_ r: HoldingTime.Report) -> some View {
        VStack(spacing: 0) {
            ForEach(r.buckets) { b in
                HStack(spacing: 8) {
                    bucketLabel(b.id).font(.subheadline.monospacedDigit())
                        .frame(width: 92, alignment: .leading)
                    Text(verbatim: String(format: Loc.t("%lld 笔"), b.trades.count))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    if b.hingesOnOneTrade {
                        Pill(text: Loc.t("主要靠一笔"), tint: .secondary)
                    }
                    Spacer(minLength: 4)
                    if b.trades.isEmpty {
                        Text(verbatim: "—").foregroundStyle(.tertiary)
                    } else {
                        if let w = b.summary.winRate {
                            Text(verbatim: "\(Int((w * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(verbatim: Money.signed(b.summary.total))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.pnl(b.summary.total))
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                }
                .padding(.vertical, 7)
                if b.id < r.buckets.count - 1 { Divider() }
            }
        }
        .card(padding: 12)
    }

    /// ★ 写成字面量:本地化守卫只认得出字面量。
    @ViewBuilder
    private func bucketLabel(_ i: Int) -> some View {
        switch i {
        case 0: Text("不到 2 分钟")
        case 1: Text("2–5 分钟")
        case 2: Text("5–15 分钟")
        case 3: Text("15–30 分钟")
        case 4: Text("30–60 分钟")
        case 5: Text("1 小时以上")
        default: Text("隔夜")
        }
    }

    // MARK: - 结论:只说站得住的

    @ViewBuilder
    private func verdict(_ r: HoldingTime.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = r.pHoldDiffers, let w = r.medianWinHold, let l = r.medianLossHold {
                let ws = HoldingTime.format(w, Loc.t), ls = HoldingTime.format(l, Loc.t)
                let ps = TimeOfDaySection.pctString(p)
                if p < 0.05, l > w {
                    Text(md: String(format: Loc.t(
                        "**亏单比赢单拿得久**:赢单中位 %1$@,亏单中位 %2$@ —— 随机分组做到这么大差别的概率只有 %3$@。赚了早走、亏了拿着等回本,交易心理里管这叫「处置效应」。"),
                        ws, ls, ps))
                } else if p < 0.05 {
                    Text(md: String(format: Loc.t(
                        "**赢单比亏单拿得久**:赢单中位 %1$@,亏单中位 %2$@ —— 随机分组做到这么大差别的概率只有 %3$@。"),
                        ws, ls, ps))
                } else {
                    Text(md: String(format: Loc.t(
                        "赢单中位拿 %1$@,亏单中位 %2$@ —— **差别和随机分组差不多大**(p = %3$@),看不出赢亏和拿多久有关。"),
                        ws, ls, TimeOfDaySection.pString(p)))
                }
            } else {
                Text(verbatim: String(format: Loc.t(
                    "才 %1$lld 笔开平仓时间都知道(赢 %2$lld、亏 %3$lld),还比不出赢单亏单拿多久 —— 攒到 %4$lld 笔、两边各 %5$lld 笔再看。"),
                    r.n, r.wins, r.losses, HoldingTime.minForTest, HoldingTime.minPerSide))
            }
            if let rho = r.rho, let p = r.pRho {
                let rs = String(format: "%.2f", rho), ps = TimeOfDaySection.pString(p)
                if p >= 0.05 {
                    Text(verbatim: String(format: Loc.t(
                        "整体上「拿得越久越亏(或越赚)」说不准:相关系数 %1$@,p = %2$@。"), rs, ps))
                } else if rho < 0 {
                    Text(md: String(format: Loc.t("**拿得越久,盈亏越差**:相关系数 %1$@,p = %2$@。"), rs, ps))
                } else {
                    Text(md: String(format: Loc.t("**拿得越久,盈亏越好**:相关系数 %1$@,p = %2$@。"), rs, ps))
                }
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private func excludedNote(_ r: HoldingTime.Report) -> some View {
        if r.excluded > 0 {
            Text(verbatim: String(format: Loc.t(
                "没算进来:%lld 笔开仓或平仓时间是估的,或是旧版没认出时间时填的 11:00(在复盘页改成真实时间就会算进来)。"),
                r.excluded))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
