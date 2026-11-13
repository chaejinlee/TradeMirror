import SwiftUI

/// K 线图。**四大品种共用一个** —— 股票/期权/期货/外汇都只是价格序列,不该有品种特判。
///
/// ★★ 颜色规矩(2026-09-01 用户定的):**涨绿、跌红。** 全 App 一致。
/// ★★ 数据来源必须写在图上:
///    · 有 `Leg.path`(moomoo 补过)→ **真实分钟 K**
///    · 没有 → **示意 K 线**,由成交点确定性生成。形状是编的,**成交点是真的**。
///      标注写死在图里,不给「看着像真的」留任何余地。
struct CandleChart: View {
    let bars: [PriceBar]
    /// 成交点:价格 + 是买是卖。画成横线,让你一眼看出加仓/出场在哪个价位。
    let marks: [Mark]
    let isReal: Bool
    var height: CGFloat = 150

    struct Mark: Identifiable {
        let id = UUID()
        let px: Double
        let isBuy: Bool
    }

    private var lo: Double {
        min(bars.map(\.l).min() ?? 0, marks.map(\.px).min() ?? .greatestFiniteMagnitude)
    }
    private var hi: Double {
        max(bars.map(\.h).max() ?? 1, marks.map(\.px).max() ?? -.greatestFiniteMagnitude)
    }
    /// 上一根的收盘当作这一根的开盘 —— 分钟 K 之间本来就是连着的。
    private func open(at i: Int) -> Double { i == 0 ? bars[i].c : bars[i - 1].c }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let span = max(hi - lo, 1e-9)
                let w = geo.size.width
                let h = geo.size.height
                let slot = w / CGFloat(max(bars.count, 1))
                ZStack(alignment: .topLeading) {
                    ForEach(marks) { m in
                        Path { p in
                            let yy = h - CGFloat((m.px - lo) / span) * h
                            p.move(to: CGPoint(x: 0, y: yy))
                            p.addLine(to: CGPoint(x: w, y: yy))
                        }
                        .stroke(m.isBuy ? Theme.buy.opacity(0.55) : Theme.sell.opacity(0.55),
                                style: .init(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, bar in
                        Candle(bar: bar, open: open(at: i), lo: lo, span: span,
                               x: slot * (CGFloat(i) + 0.5),
                               width: max(slot * 0.62, 1), height: h)
                    }
                }
            }
            .frame(height: height)

            HStack(spacing: 6) {
                Image(systemName: isReal ? "checkmark.seal.fill" : "scribble")
                    .foregroundStyle(isReal ? Theme.profit : Color.secondary)
                Text(isReal
                     ? "真实分钟 K · \(bars.count) 根"
                     : "示意 K 线 —— 形状是按成交点编的,别从图上读价格")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("买").font(.caption2).foregroundStyle(Theme.buy)
                Text("卖").font(.caption2).foregroundStyle(Theme.sell)
            }
        }
    }
}

/// 一根蜡烛。**涨绿跌红。**
private struct Candle: View {
    let bar: PriceBar
    let open: Double
    let lo: Double
    let span: Double
    let x: CGFloat
    let width: CGFloat
    let height: CGFloat

    private func y(_ v: Double) -> CGFloat { height - CGFloat((v - lo) / span) * height }
    private var up: Bool { bar.c >= open }

    var body: some View {
        let color = up ? Theme.profit : Theme.loss
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: x, y: y(bar.h)))
                p.addLine(to: CGPoint(x: x, y: y(bar.l)))
            }.stroke(color, lineWidth: max(width * 0.2, 0.7))
            Path { p in
                let top = y(max(open, bar.c))
                let bot = y(min(open, bar.c))
                p.addRect(CGRect(x: x - width / 2, y: top,
                                 width: width, height: max(bot - top, 1)))
            }.fill(color)
        }
    }
}
