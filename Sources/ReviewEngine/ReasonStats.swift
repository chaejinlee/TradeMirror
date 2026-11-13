import Foundation

/// 按**原因**汇总。
///
/// ★★ 用户 2026-09-02 的要求:「开单原因汇总整理,止损,出场原因」。
///   他自己的 CSV 里一直有 `理由_主 / 止损 / 出场原因` 这三列 ——
///   说明他早就在按原因思考,而 App 之前只存了「出场原因」一个自由文本,
///   **从来没有把它们聚起来看过**。
///
/// ★ 为什么按原因分组比看胜率有用:胜率告诉你「赢了几次」,
///   按原因分组告诉你「**哪一类判断值钱、哪一类不值**」——后者才能改行为。
///
/// ★ 样本纪律:每组都带 `n`,**由界面决定几笔以下不给结论**。
///   这里不偷偷过滤,也不偷偷补全 —— 空的就是空的。
public struct ReasonBucket: Sendable, Identifiable, Equatable {
    public var id: String { reason }
    public var reason: String
    public var n: Int
    public var wins: Int
    public var totalPnL: Double
    /// 这组里「持有到收盘会更好」的次数(可执行反事实,不含峰值)。
    public var holdWouldBeBetter: Int
    public var winRate: Double { n > 0 ? Double(wins) / Double(n) : 0 }
    public var avgPnL: Double { n > 0 ? totalPnL / Double(n) : 0 }
}

public struct ReasonStats: Sendable {
    /// 按开单原因分组(只统计**已平仓**且填了原因的)。
    public var byEntryReason: [ReasonBucket]
    /// 按出场原因分组。
    public var byExitReason: [ReasonBucket]
    /// 填了止损的交易数 / 已平仓数 —— **「有多少笔是真的事前定了止损」**。
    public var withStop: Int
    public var closedCount: Int
    /// 其中**止损真的被碰到过**的笔数(需要真实分钟路径)。nil = 没有路径,算不出。
    public var stopTouched: Int?
    /// 有路径、能判定止损是否被触发的笔数。
    public var stopCheckable: Int
    /// 计划 R:R 的中位数。填了止损+止盈才算得出。
    public var medianPlannedRR: Double?
    /// ★★ **止损被触及过、而这笔最后还赚钱** —— 也就是你<b>没有按止损出场</b>。
    ///   这比「止损从未被触发」严重得多:前者是纪律,后者只是还没遇到。
    ///   同一屏上如果一边说「从未被检验」、一边说「被碰到过 3 笔」,那是自相矛盾 ——
    ///   区别就在这个字段:碰到了,但你没执行。
    public var stopTouchedButHeld: Int

    public static func compute(_ trades: [Trade]) -> ReasonStats {
        let closed = trades.filter { !$0.isSample && $0.isClosed }

        func bucket(_ key: (Trade) -> String?) -> [ReasonBucket] {
            var agg: [String: (n: Int, w: Int, pnl: Double, hold: Int)] = [:]
            for t in closed {
                guard let k = key(t)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !k.isEmpty else { continue }
                var e = agg[k] ?? (0, 0, 0, 0)
                e.n += 1
                let pnl = t.realizedPnL
                if pnl > 0 { e.w += 1 }
                e.pnl += pnl
                if let fin = t.finalUnderlying {
                    let cf = CounterfactualEngine.holdToClose(trade: t, finalUnderlying: fin)
                    if cf.verdict == .alternativeWasBetter { e.hold += 1 }
                }
                agg[k] = e
            }
            return agg.map { k, v in
                ReasonBucket(reason: k, n: v.n, wins: v.w,
                             totalPnL: v.pnl, holdWouldBeBetter: v.hold)
            }
            // 笔数多的在前;同笔数按累计盈亏
            .sorted { ($0.n, $0.totalPnL) > ($1.n, $1.totalPnL) }
        }

        let withStop = closed.filter { $0.plannedStop != nil }.count
        let touchable = closed.compactMap { $0.stopWasTouched() }
        let rrs = closed.compactMap(\.plannedRR).sorted()
        let median: Double? = rrs.isEmpty ? nil
            : (rrs.count % 2 == 1 ? rrs[rrs.count / 2]
               : (rrs[rrs.count / 2 - 1] + rrs[rrs.count / 2]) / 2)

        let touchedButHeld = closed.filter {
            $0.stopWasTouched() == true && $0.realizedPnL > 0
        }.count
        return ReasonStats(byEntryReason: bucket { $0.entryReason },
                           byExitReason: bucket { $0.exitReason },
                           withStop: withStop,
                           closedCount: closed.count,
                           stopTouched: touchable.isEmpty ? nil : touchable.filter { $0 }.count,
                           stopCheckable: touchable.count,
                           medianPlannedRR: median,
                           stopTouchedButHeld: touchedButHeld)
    }
}

/// 开单原因的常用选项。★ 取自用户自己 CSV 里的 `理由_主` 列 ——
/// 不是我编的分类,是他已经在用的词。
public enum EntryReason {
    public static let presets = ["结构位", "趋势跟随", "量价信号", "均线反应",
                                 "缺口回补", "突破回踩", "消息面", "其他"]
}

/// 出场原因的常用选项。同样取自他的 CSV(`出场原因` 列)。
public enum ExitReason {
    public static let presets = ["触及目标", "触及止损", "提前手动平", "破位离场",
                                 "时间到了", "收盘平掉", "其他"]
}
