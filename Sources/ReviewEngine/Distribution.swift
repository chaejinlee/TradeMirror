import Foundation

/// **单笔盈亏的分布** —— 一格一笔的直方图。
///
/// ★★ 为什么值得单独做一层纯逻辑:
///   分箱是算术,而这个 App 的算术已经栽过好几次(归日时区、周起点、千位逗号)。
///   摆在引擎里能写测试;<b>摆在视图里就又是一处没人测的判断。</b>
///
/// ★★ 一条硬规矩:<b>0 必须落在箱子的边界上,不能落在箱子中间。</b>
///   横跨 0 的箱子会把赚的和亏的混进同一根柱子 —— 那根柱子就在说谎。
///   所以分箱是**从 0 往两边铺**,不是从最小值开始铺。
/// ★ 不做 `Equatable`:`Trade` 不是,而按引用比箱子也没意义 —— 测试比 `count` 和边界。
public struct DistributionBin: Sendable, Identifiable {
    /// 左闭。
    public var lo: Double
    /// 右开。
    public var hi: Double
    /// 落在这一档里的交易,按盈亏从小到大。
    public var trades: [Trade]

    public var id: Double { lo }
    public var count: Int { trades.count }
    /// 这一档整体是赚是亏。★ 因为 0 在边界上,一档里不会同时有赚有亏。
    public var isProfit: Bool { lo >= 0 }
}

/// 一段样本的汇总。**每一项都可能是 nil** —— 没有样本就别编一个数出来。
public struct DistributionSummary: Sendable, Equatable {
    public var n: Int
    public var wins: Int
    public var losses: Int
    public var total: Double
    public var avgWin: Double?
    public var avgLoss: Double?
    public var best: Double?
    public var worst: Double?

    /// 平均盈利率 / 平均亏损率(小数,`0.489` = +48.9%)。
    ///
    /// ★★ 分母是 `returnOnDebit` 的分母 —— **净借记,你真正付出去的钱**。
    ///   贷记开仓(卖 put、卖价差)算不出来,那些笔<b>不进这两个平均</b> ——
    ///   见 `Trade.returnOnDebit` 里那段:宁可不给,也不给一个分母不对的百分比。
    ///
    /// ★★ 和金额口径**会给出不同的结论**,这不是 bug,是两个问题:
    ///   用户 2026-09-18 的 23 笔 —— 金额 $279/$408 = 0.68,百分比 49%/63% = 0.78。
    ///   <b>金额问「一笔赚多少」,百分比问「一块钱赚多少」。</b>
    ///   仓位大小不一样时两者必然分叉,界面要把两行并排摆出来。
    public var avgWinPct: Double?
    public var avgLossPct: Double?

    /// 真正参与上面两个平均的笔数。
    /// ★ 可能**小于** `wins` / `losses`(贷记开仓没有百分比)——
    ///   界面必须能看出差额,否则「平均 49%」会被当成 16 笔的平均而其实只有 13 笔。
    public var winsWithPct: Int = 0
    public var lossesWithPct: Int = 0

    /// 每一笔都算得出百分比。
    public var pctCoversEveryTrade: Bool { winsWithPct == wins && lossesWithPct == losses }

    /// **中位数** —— 「一笔典型的赢单 / 亏单」。百分比的两个只统计算得出百分比的那些(同平均)。
    ///
    /// ★ 用户 2026-10-05:「添加获胜金额、获胜百分比的中位数」。
    ///   平均会被一两笔大单拉走:那天的 58 笔里平均盈 $258、**中位盈 $122**;
    ///   平均亏 −$379、**中位亏 −$182**。<b>平均问「总共赚了多少摊到每笔」,中位问「通常一笔赚多少」</b>,
    ///   两个都要摆出来 —— 差得越远,说明越是靠少数几笔大单。
    public var medianWin: Double? = nil
    public var medianLoss: Double? = nil
    public var medianWinPct: Double? = nil
    public var medianLossPct: Double? = nil

    /// 中位盈 ÷ |中位亏|。同样两边都要有样本。
    public var medianPayoffRatio: Double? {
        guard let w = medianWin, let l = medianLoss, l != 0 else { return nil }
        return w / abs(l)
    }
    public var medianPayoffRatioPct: Double? {
        guard let w = medianWinPct, let l = medianLossPct, l != 0 else { return nil }
        return w / abs(l)
    }

    /// 百分比口径的盈亏比。同样**两边都要有样本**才给。
    public var payoffRatioPct: Double? {
        guard let w = avgWinPct, let l = avgLossPct, l != 0 else { return nil }
        return w / abs(l)
    }

    public var winRate: Double? { n > 0 ? Double(wins) / Double(n) : nil }

    /// 平均盈 ÷ 平均亏。★ **两边都要有样本才给** ——
    /// 只有盈利单时给个「∞」或者「0」都是在骗人。
    public var payoffRatio: Double? {
        guard let w = avgWin, let l = avgLoss, l != 0 else { return nil }
        return w / abs(l)
    }

    /// 期望值:每笔平均能指望赚多少。同样要两边都有样本。
    public var expectancy: Double? {
        guard n > 0, avgWin != nil, avgLoss != nil else { return nil }
        return total / Double(n)
    }
}

public enum Distribution {

    /// 只看**已平仓、非样本**的交易 —— 未平仓没有已实现盈亏,不能进分布。
    /// ★ 这和热力图、胜率用的是同一条规矩,不许各写一套。
    public static func eligible(_ trades: [Trade]) -> [Trade] {
        trades.filter { !$0.isSample && $0.isClosed && $0.displayablePnL != nil }
    }

    /// 档宽:**1 / 2 / 5 阶梯**,按样本的绝对值范围挑。
    ///
    /// ★★ 必须自适应。用户 2026-09-18 的数据里最大一笔 $1,236、最小 −$893,
    ///   $200 一档刚好;但他的仓位一直在变大(8 月做 1–5 张,9 月做 20–33 张),
    ///   <b>写死的档宽过几周就不够用了</b> —— 那时候所有柱子会挤成一根。
    /// - Parameter target: 想要多少档(左右合计)。真实档数会因为对齐到阶梯而浮动。
    public static func binWidth(_ values: [Double], target: Int = 14) -> Double {
        let maxAbs = values.map(abs).max() ?? 0
        guard maxAbs > 0, target > 0 else { return 100 }
        let span = maxAbs * 2

        // ★★ 不能「先算 raw 再就近吸附到阶梯」—— 那样 raw=206 会跳到 500,
        //   2472/500 只剩 5 档,<b>14 笔全挤进 0 右边那一根柱子</b>(实测截图就是这样)。
        //   ⇒ 改成:把阶梯上的候选**一个个试**,取「档数最接近 target」的那个。
        let raw = span / Double(target)
        let k = floor(log10(raw))
        var best = max(1, raw), bestErr = Double.infinity
        for e in [k - 1, k, k + 1] {
            let mag = pow(10, e)
            for step in [1.0, 2, 5] {
                let w = step * mag
                guard w > 0 else { continue }
                let n = ceil(span / w)
                guard n >= 4, n <= 40 else { continue }     // 太少看不出形状,太多挤成一片
                let err = abs(n - Double(target))
                if err < bestErr { bestErr = err; best = w }
            }
        }
        return best
    }

    /// 把交易铺成一排箱子。
    ///
    /// ★ 空箱子**保留** —— 中间挖个洞正是分布要给人看的东西
    ///   (「我没有中等大小的亏损,要么小亏要么巨亏」)。
    public static func bins(_ trades: [Trade], width: Double? = nil) -> [DistributionBin] {
        let xs = eligible(trades)
        guard !xs.isEmpty else { return [] }
        let pnl = xs.compactMap(\.displayablePnL)
        let w = width ?? binWidth(pnl)
        guard w > 0 else { return [] }

        // ★★ 从 0 往两边铺:`floor(p / w)` 对负数向下取整,正好让 0 成为边界。
        let idx = pnl.map { Int(floor($0 / w)) }
        guard let lo = idx.min(), let hi = idx.max() else { return [] }

        var buckets = [Int: [Trade]]()
        for t in xs {
            let i = Int(floor((t.displayablePnL ?? 0) / w))
            buckets[i, default: []].append(t)
        }
        return (lo...hi).map { i in
            DistributionBin(lo: Double(i) * w, hi: Double(i + 1) * w,
                            trades: (buckets[i] ?? []).sorted {
                                ($0.displayablePnL ?? 0) < ($1.displayablePnL ?? 0) })
        }
    }

    public static func summary(_ trades: [Trade]) -> DistributionSummary {
        let ts = eligible(trades)
        // ★ 盈亏先按美分取整再统计(见 `Money.cents`):中位数、平均、赢亏分界都不许被 1e-14 左右的误差带偏
        let pnl = { (t: Trade) in t.displayablePnL.map(Money.cents) }
        let xs = ts.compactMap(pnl)
        let w = xs.filter { $0 > 0 }, l = xs.filter { $0 <= 0 }

        // ★ 百分比只统计**算得出来**的那些 —— 贷记开仓的 `returnOnDebit` 是 nil
        let rw = ts.filter { (pnl($0) ?? 0) > 0 }.compactMap(\.returnOnDebit)
        let rl = ts.filter { (pnl($0) ?? 0) <= 0 }.compactMap(\.returnOnDebit)

        var s = DistributionSummary(
            n: xs.count, wins: w.count, losses: l.count, total: xs.reduce(0, +),
            avgWin: w.isEmpty ? nil : w.reduce(0, +) / Double(w.count),
            avgLoss: l.isEmpty ? nil : l.reduce(0, +) / Double(l.count),
            best: xs.max(), worst: xs.min())
        s.avgWinPct = rw.isEmpty ? nil : rw.reduce(0, +) / Double(rw.count)
        s.avgLossPct = rl.isEmpty ? nil : rl.reduce(0, +) / Double(rl.count)
        s.winsWithPct = rw.count
        s.lossesWithPct = rl.count
        s.medianWin = median(w); s.medianLoss = median(l)
        s.medianWinPct = median(rw); s.medianLossPct = median(rl)
        return s
    }

    /// 中位数;偶数个取中间两个的平均。空 ⇒ nil(不是 0)。
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    // MARK: - 切片

    /// 按**加仓次数**分组。
    ///
    /// ★★ 这一刀是数据自己指出来的:用户 2026-09-18 导出的 23 笔里,
    ///   加仓 ≥3 次的只有 2 笔,合计 <b>−$1,689</b> —— 比他全部净利润($1,607)还多。
    ///   <b>去掉那 2 笔,其余 21 笔是 +$3,296。</b>
    public enum AddsBucket: String, Sendable, CaseIterable, Identifiable {
        case none, few, many
        public var id: String { rawValue }
        /// ★ 引擎里不许出现裸中文 —— 译文由调用方传进来(守卫会盯着这条)。
        public func label(_ L: (String) -> String = { $0 }) -> String {
            switch self {
            case .none: L("没加仓")
            case .few:  L("加仓 1-2 次")
            case .many: L("加仓 ≥3 次")
            }
        }
        static func of(_ n: Int) -> AddsBucket { n == 0 ? .none : (n <= 2 ? .few : .many) }
    }

    /// 一笔里**同向加仓**了几次(与首笔同向的成交数 − 1)。
    /// ★ 和 `addsWhileUnderwater` 不同:那个只数浮亏时加的,这个数全部。
    public static func addCount(_ t: Trade) -> Int {
        t.legs.reduce(0) { acc, leg in acc + max(0, t.openingFills(of: leg).count - 1) }
    }

    public static func byAdds(_ trades: [Trade]) -> [(AddsBucket, [Trade])] {
        let xs = eligible(trades)
        return AddsBucket.allCases.compactMap { b in
            let g = xs.filter { AddsBucket.of(addCount($0)) == b }
            return g.isEmpty ? nil : (b, g)
        }
    }

    /// 按**出场原因**分组。没填的归到 `nil` 那一组,**不许算成「其他」** ——
    /// 「没填」和「填了其他」是两件事。
    public static func byExitReason(_ trades: [Trade]) -> [(String?, [Trade])] {
        let xs = eligible(trades)
        let keys = Array(Set(xs.map { $0.exitReason?.isEmpty == false ? $0.exitReason : nil }))
        return keys.map { k in (k, xs.filter {
            ($0.exitReason?.isEmpty == false ? $0.exitReason : nil) == k }) }
            .sorted { $0.1.count > $1.1.count }
    }
}
