import SwiftUI

/// 反事实分叉图 —— 这一页的主视觉。
///
/// ★ 它画的就是 App 图标那件事:**一条实线是你走的,几条虚线是你没走的。**
/// 共同段 = 持仓中(所有路径一样),分叉点 = 你做出场决定的那一刻,
/// 之后每条分支落在各自的盈亏上。
///
/// ★★ 刻意**不画价格路径**:这张图回答的是「出场那一下换个做法会怎样」,
/// 横轴是**决定的前后**,不是时间。真实走势由 `CandleChart` 负责(v1.8 起是真的分钟 K)。
/// 横轴只是「决策之前 / 决策之后」,不是时间刻度。宁可少画,不许假装有数据。
struct ForkChart: View {
    let actualPnL: Double
    /// (标签, 盈亏, 是否「那样更好」)
    let branches: [(label: String, pnl: Double, alternativeBetter: Bool)]

    private var all: [Double] { [0, actualPnL] + branches.map(\.pnl) }
    private var lo: Double { min(all.min() ?? 0, 0) }
    private var hi: Double { max(all.max() ?? 0, 0) }
    private var span: Double { max(hi - lo, 1) }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let pad: CGFloat = 26
        return pad + (1 - CGFloat((v - lo) / span)) * (h - pad * 2)
    }

    /// 标签的 y:把各分支按终点高度排序,**强制最小间距**,避免叠字。
    /// 你自己那条(黑线)也参与占位 —— 它在 `youY` 里单独传进来。
    private func labelY(at i: Int, endY: CGFloat, h: CGFloat) -> CGFloat {
        let slots = layoutSlots(h: h).branch
        return slots.indices.contains(i) ? slots[i] : endY
    }

    /// 一次性把所有标签位算好:按终点 y 排序,自上而下拉开至少 15pt。
    ///
    /// ★ 「你」那条也要一起排 —— 它以前各画各的,所以分支再怎么错开,
    ///   还是会有一条压在它身上(真实数据 5 条分支时当场撞上)。
    /// 返回 (分支各自的 y, 「你」的 y)。
    private func layoutSlots(h: CGFloat) -> (branch: [CGFloat], you: CGFloat) {
        let gap: CGFloat = 15
        // −1 代表「你」那条
        var items = branches.indices.map { ($0, y(branches[$0].pnl, h)) }
        items.append((-1, y(actualPnL, h)))
        items.sort { $0.1 < $1.1 }
        var out = [CGFloat](repeating: 0, count: branches.count)
        var youY = y(actualPnL, h)
        var last: CGFloat = -.greatestFiniteMagnitude
        for (i, want) in items {
            let put = max(want, last + gap)
            if i < 0 { youY = put } else { out[i] = put }
            last = put
        }
        return (out, youY)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let forkX = w * 0.26
            // ★ 实测:endX 0.72 时长标签会溢出屏幕右边被切掉。
            //   收到 0.56,并配合短标签(见 ReviewView 里的 shortLabel)。
            let endX  = w * 0.56
            let y0 = y(0, h)

            ZStack(alignment: .topLeading) {
                // 零轴
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y0)); p.addLine(to: CGPoint(x: w, y: y0))
                }
                .stroke(Color.secondary.opacity(0.18), style: .init(lineWidth: 1, dash: [3, 4]))

                // 分支(虚线):没走的那些
                // ★★ 2026-09-24:原来是「替代更好 = 红、你更好 = 绿」——
                //   而全 App 里红绿的意思是**亏 / 赚**,这里却表示**比较**,同一个颜色两种意思。
                //   ⇒ 改成 App 图标那套:**你没走的路 = 琥珀色虚线**。
                //     更好的那条画实一点(那是你错过的),更差的淡一点(那是你躲开的)。
                //     好坏由终点高低和下面卡片里的标签说,不靠红绿。
                ForEach(Array(branches.enumerated()), id: \.offset) { i, b in
                    let ye = y(b.pnl, h)
                    curve(from: CGPoint(x: forkX, y: y0), to: CGPoint(x: endX, y: ye))
                        .stroke(Theme.alt.opacity(b.alternativeBetter ? 0.95 : 0.4),
                                style: .init(lineWidth: 3, lineCap: .round, dash: [7, 6]))
                    Circle()
                        .fill(Theme.alt.opacity(b.alternativeBetter ? 0.95 : 0.4))
                        .frame(width: 7, height: 7)
                        .position(x: endX, y: ye)
                    // ★ 2026-09-01 导入真实历史后暴露:五条分支时标签**叠在一起看不清**
                    //   (「你」「平一半+跟踪」「移动止损」挤成一坨)。
                    //   分支多了以后,按 pnl 排名把标签**错开**,不再各画各的。
                    // ★ 分支名来自引擎(运行时 String)—— 必须包 LocalizedStringKey
                    Text(LocalizedStringKey(b.label))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(b.alternativeBetter ? Theme.alt : Color.secondary)
                        .lineLimit(1)
                        .frame(width: w - endX - 18, alignment: .leading)
                        .position(x: endX + (w - endX - 18) / 2 + 14,
                                  y: labelY(at: i, endY: ye, h: h))
                }

                // 共同段 + 实线:你实际走的
                let ya = y(actualPnL, h)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.04, y: y0))
                    p.addLine(to: CGPoint(x: forkX, y: y0))
                }
                .stroke(Color.primary.opacity(0.75), style: .init(lineWidth: 3.5, lineCap: .round))

                curve(from: CGPoint(x: forkX, y: y0), to: CGPoint(x: endX, y: ya))
                    .stroke(Color.primary, style: .init(lineWidth: 3.5, lineCap: .round))
                Circle().fill(Color.primary).frame(width: 10, height: 10)
                    .position(x: endX, y: ya)
                Text("你").font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.primary)
                    .frame(width: w - endX - 18, alignment: .leading)
                    .position(x: endX + (w - endX - 18) / 2 + 14,
                              y: layoutSlots(h: h).you)

                // 分叉点
                Circle().fill(Color(.systemBackground))
                    .frame(width: 13, height: 13).position(x: forkX, y: y0)
                Circle().stroke(Color.primary, lineWidth: 2.5)
                    .frame(width: 13, height: 13).position(x: forkX, y: y0)
                Text("出场决定").font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .position(x: forkX, y: y0).offset(y: 18)
            }
        }
        .frame(height: 170)
        .padding(.vertical, 4)
    }

    private func curve(from a: CGPoint, to b: CGPoint) -> Path {
        Path { p in
            p.move(to: a)
            p.addCurve(to: b,
                       control1: CGPoint(x: a.x + (b.x - a.x) * 0.45, y: a.y),
                       control2: CGPoint(x: a.x + (b.x - a.x) * 0.55, y: b.y))
        }
    }
}
