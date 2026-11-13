import Foundation

/// 持仓期间这条腿的**真实分钟路径**。v10 新增。
///
/// ★★ 为什么值得单独存:App 里两条「算不了的」都卡在同一件事上 ——
///   ① 「平一半 + 剩余移动止损」的完整版:移动止损<b>何时触发</b>要看价格的**顺序**,
///      只有最高价和最低价是不够的。
///   ② 真正的 MAE:过去只能从**成交点**观测,所以界面上写的是「≥」。
///
///   用户有 moomoo,而 moomoo 有分钟 K(实测)。
///   ⇒ 在电脑上取,存进备份,导回 App。逻辑仍然全部在引擎里 ——
///     这样它可测,而且不依赖任何联网。
public struct PriceBar: Codable, Sendable, Equatable {
    public var t: Date
    public var h: Double
    public var l: Double
    public var c: Double
    public init(t: Date, h: Double, l: Double, c: Double) {
        self.t = t; self.h = h; self.l = l; self.c = c
    }
}

public enum PathAnalysis {

    /// 按时间窗切片。
    ///
    /// ★★ 2026-09-01 实测踩到的坑:我把路径从「入场→出场」扩到「入场→当天收盘」
    ///   (因为「平一半、剩余持有」需要你走之后的数据),
    ///   结果 **MAE 从 −11.2% 变成 −93.3%,MFE 从 +82.1% 变成 +228.4%** ——
    ///   那是**当天全程**的极值,不是**你持仓期间**的。
    ///   MAE/MFE 的定义就是「持仓期间」,拿全天的数去填等于换了个意思还用原来的标签。
    ///   ⇒ 同一条路径,不同的问题要切不同的窗。
    public static func slice(_ path: [PriceBar], from: Date? = nil, to: Date? = nil) -> [PriceBar] {
        path.filter { b in
            (from.map { b.t >= $0 } ?? true) && (to.map { b.t <= $0 } ?? true)
        }
    }

    /// 真 MAE:入场后价格<b>最不利</b>的那一刻,相对入场价的百分比。
    /// 多头腿看最低价,空头腿看最高价。**返回负数**(或 0)。
    ///
    /// ★ 和旧的 `observedMAE` 的区别:旧的只看**成交点**,
    ///   所以只能说「至少跌了这么多」,界面上得写「≥」。这个是真的。
    public static func trueMAE(path: [PriceBar], entry: Double, isLong: Bool) -> Double? {
        guard !path.isEmpty, entry > 0 else { return nil }
        let worst = isLong ? path.map(\.l).min()! : path.map(\.h).max()!
        let pct = (isLong ? worst - entry : entry - worst) / entry * 100
        return min(pct, 0)
    }

    /// 真 MFE:入场后价格<b>最有利</b>的那一刻。**返回正数**(或 0)。
    public static func trueMFE(path: [PriceBar], entry: Double, isLong: Bool) -> Double? {
        guard !path.isEmpty, entry > 0 else { return nil }
        let best = isLong ? path.map(\.h).max()! : path.map(\.l).min()!
        let pct = (isLong ? best - entry : entry - best) / entry * 100
        return max(pct, 0)
    }

    /// MFE 捕获率:你实际拿到的,占「最好那一刻」的多少。
    /// ★ 这是行业标准说法(「平均 MFE 3.4R,实际出场 1.7R ⇒ 只吃到 50%」)。
    public static func mfeCapture(path: [PriceBar], entry: Double, exit: Double,
                                  isLong: Bool) -> Double? {
        guard let mfe = trueMFE(path: path, entry: entry, isLong: isLong), mfe > 0 else { return nil }
        let got = (isLong ? exit - entry : entry - exit) / entry * 100
        return got / mfe
    }

    /// **移动止损模拟。**从入场开始跟踪最有利价,回撤 `trailPct` 就出场。
    ///
    /// ★ 返回的是**出场价**;全程没触发则返回 nil(表示「一直没被打掉」)。
    /// ★ 用每根 K 的**不利端**判定触发(多头用 low),这是保守且诚实的做法 ——
    ///   假装能在 close 才触发会系统性地高估这条策略。
    /// ★★ 同一根 K 内先到高点还是先到低点,分钟数据里**看不出来**。
    ///   所以这里用**上一根为止**的最高价来定止损位,判完这根再更新最高 ——
    ///   也就是「<b>只能用已经完成的信息下单</b>」。
    ///
    ///   我第一版写反了:先更新最高、再判触发。那等于允许用**这根 K 后面才出现的高点**
    ///   把止损抬上去,再去打掉**这根 K 前面就出现过的低点** —— 是回测里的未来函数。
    ///   实测在用户那笔上直接造成误判(1.36→1.90 那一分钟被判成触发)。
    public static func trailingStopExit(path: [PriceBar], entry: Double,
                                        trailPct: Double, isLong: Bool) -> Double? {
        guard !path.isEmpty, entry > 0, trailPct > 0 else { return nil }
        var peak = entry
        for bar in path {
            if isLong {
                let stop = peak * (1 - trailPct / 100)     // 用**这根之前**的最高价
                if bar.l <= stop { return stop }
                peak = max(peak, bar.h)                    // 判完才更新
            } else {
                let stop = peak * (1 + trailPct / 100)
                if bar.h >= stop { return stop }
                peak = min(peak, bar.l)
            }
        }
        return nil
    }
}
