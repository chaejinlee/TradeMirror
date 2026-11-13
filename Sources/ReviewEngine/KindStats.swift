import Foundation

/// 按**交易种类**分类的战绩:品种 / 方向 / 策略 / 标的。
///
/// ★★ 一条设计纪律:**只有一个取值的维度,不给它一整块地方。**
///   4 笔全是期权时,画一行「期权 4 笔 $705」等于把用户已经知道的事占掉一行 ——
///   分类的意义是**对比**,一个格子没有对比。
///
/// ⚠️ 但 2026-09-02 我把这条用错了:`groups` 直接把单值维度**整个剔掉**,
///   于是用户手机上停在「日」时(那天只有一笔)**连入口一起消失** ——
///   他来问「我手机上怎么没有按种类看」。
///   <b>一个自动隐藏的功能,和一个坏掉的功能,从用户那边看没有区别。</b>
///
///   ⇒ 我把两件事混成了一件:
///     「不浪费一整块」是对的,「连入口一起藏掉」是错的。
///     现在:单值维度降级成**一行摘要**(`singles`),而不是消失。
///
/// ★ 和 `PeriodStats` 共用同一个周期口径:分类分的是**当前显示的那个周期**,
///   不是全部历史。否则主页上两个数会打架(上面写「8 月 705」、
///   下面按品种加起来却是全年的)。
public struct KindBucket: Sendable, Identifiable, Equatable {
    public var id: String { label }
    public var label: String
    public var n: Int
    public var wins: Int
    public var pnl: Double
    /// 还没平的笔数(不进盈亏,但要能显示出来)。
    public var openCount: Int
    public var winRate: Double { n > 0 ? Double(wins) / Double(n) : 0 }
}

public struct KindGroup: Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    /// **按累计盈亏从高到低。**
    public var buckets: [KindBucket]
}

public enum KindStats {

    /// 品种:股票/ETF · 期权 · 期货 · 外汇。多腿混合时按第一条腿算。
    static func instrument(_ t: Trade) -> String {
        guard let k = t.legs.first?.kind else { return L("未知") }
        return k.category
    }

    /// 方向。★ 期权说 Call/Put(这是交易者真正用的词),
    ///   线性品种说 做多/做空(由**首笔成交**决定,不看任何「方向」字段)。
    static func direction(_ t: Trade) -> String? {
        guard let leg = t.legs.first, let side = t.openingSide(of: leg) else { return nil }
        switch leg.kind {
        case .option(let r, _, _):
            // 买 Call / 卖 Call / 买 Put / 卖 Put —— 四种,别合成两种
            // ★ 「买 Call」这四种是**显示用**的组合词,不是存档值 —— 整句当 key
            return side == .buy ? (r == .call ? L("买 Call") : L("买 Put"))
                                : (r == .call ? L("卖 Call") : L("卖 Put"))
        case .equity, .futures, .forex:
            return side == .buy ? L("做多") : L("做空")
        }
    }

    /// 分类结果:有对比价值的维度 + 单值维度的一行摘要。
    public struct Breakdown: Sendable {
        /// 取值 ≥ 2 个 —— 给完整一块。
        public var groups: [KindGroup]
        /// 只有一个取值 —— 降级成一行,例如「品种:全是期权」。
        /// ★ 不是删掉:删掉会让用户以为功能没了。
        public var singles: [String]
        /// 一共几笔参与了分类(含未平仓)。少于 2 笔时界面该提示「换个周期看」。
        public var n: Int

        public var isEmpty: Bool { groups.isEmpty && singles.isEmpty }
    }

    /// 全部分组。
    public static func breakdown(_ trades: [Trade]) -> Breakdown {
        let real = trades.filter { !$0.isSample }
        guard !real.isEmpty else { return Breakdown(groups: [], singles: [], n: 0) }

        var groups: [KindGroup] = []
        var singles: [String] = []

        func group(_ title: String, _ key: (Trade) -> String?) -> KindGroup? {
            var agg: [String: (n: Int, w: Int, pnl: Double, open: Int)] = [:]
            for t in real {
                guard let k = key(t) else { continue }
                var e = agg[k] ?? (0, 0, 0, 0)
                if t.isClosed {
                    e.n += 1
                    let p = t.realizedPnL
                    e.pnl += p
                    if p > 0 { e.w += 1 }
                } else {
                    e.open += 1
                }
                agg[k] = e
            }
            // ★ 只有一类 = 没有对比 ⇒ **降级成一行摘要**,不是删掉
            if agg.count == 1, let only = agg.first {
                // ★ `only.key` 可能是**存档值**(如 StrategyKind 的「单腿」)——
                //   存的是中文,显示要翻。L() 查不到就原样返回,安全。
                singles.append(String(format: L("%1$@:全是%2$@"), title, L(only.key)))
                return nil
            }
            guard agg.count >= 2 else { return nil }
            let buckets = agg.map {
                KindBucket(label: $0.key, n: $0.value.n, wins: $0.value.w,
                           pnl: $0.value.pnl, openCount: $0.value.open)
            }.sorted { ($0.pnl, $0.n) > ($1.pnl, $1.n) }
            return KindGroup(title: title, buckets: buckets)
        }

        for g in [group(L("品种"), instrument),
                  group(L("方向"), direction),
                  // ★ rawValue 是**存档值**,这里只是拿来分组;显示时由 App 侧翻
                  group(L("策略")) { $0.strategy.rawValue },
                  group(L("标的")) { $0.symbol.uppercased() }] {
            if let g { groups.append(g) }
        }
        return Breakdown(groups: groups, singles: singles, n: real.count)
    }

    /// 兼容旧调用:只要有对比价值的那些维度。
    public static func groups(_ trades: [Trade]) -> [KindGroup] {
        breakdown(trades).groups
    }
}

public extension LegKind {
    /// 粗分类。★ `shortLabel` 给的是「717C」「MNQ」这种**具体合约**,
    /// 分类统计要的是**品种**这一层 —— 两个不同的问题,别复用。
    var category: String {
        switch self {
        case .equity:  return L("股票/ETF")
        case .option:  return L("期权")
        case .futures: return L("期货")
        case .forex:   return L("外汇")
        }
    }
}
