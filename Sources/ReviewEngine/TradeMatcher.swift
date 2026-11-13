import Foundation

/// 判断一张新导入的截图,该**并进已有交易**还是**新建一笔**。
///
/// ★ 这个文件来自 2026-09-01 用户的一笔真实交易:
/// Wealthsimple 上买入和卖出是**两个独立的成交详情页**,也就是两张截图。
/// 而它们是**同一笔交易**(QQQ Sep 1 708 Call,10:13 买 3 张、10:35 卖 3 张)。
/// 若第二张截图新建一笔,结果是两条孤立记录,**反事实一条都算不出来** ——
/// 因为反事实需要「开仓 + 平仓」都在同一笔里。
public enum TradeMatcher {

    public struct Match: Sendable {
        public var trade: Trade
        public var leg: Leg
        /// 为什么判定是同一笔(给界面显示,让用户能核对)。
        public var reason: String
    }

    /// 在已有交易里找这张截图应该并进去的那一笔。
    ///
    /// 判定条件(全部满足才算):
    /// 1. 标的相同
    /// 2. 合约相同(期权:Call/Put + 行权价 + 到期日;线性品种:同标的即可)
    /// 3. **那条腿还没平完** —— 已平的交易不该被继续追加
    /// 4. 新成交的方向与在手方向**相反**,或同向加仓
    ///
    /// 找不到返回 nil ⇒ 新建一笔。**宁可让用户多点一下,也不要并错。**
    public static func find(for parsed: ParsedTrade, in trades: [Trade],
                            calendar: Calendar = .current) -> Match? {
        guard let sym = parsed.symbol?.value.uppercased() else { return nil }
        for t in trades where t.symbol.uppercased() == sym {
            for leg in t.legs {
                guard abs(t.netQuantity(of: leg)) > 1e-9 else { continue }   // 已平完,跳过
                switch leg.kind {
                case .option(let r, let k, let e):
                    guard let pr = parsed.right?.value, pr == r else { continue }
                    guard let pk = parsed.strike?.value, abs(pk - k) < 1e-6 else { continue }
                    if let pe = parsed.expiry?.value {
                        let c = calendar.dateComponents([.month, .day], from: e)
                        guard pe.month == nil || pe.month == c.month,
                              pe.day == nil || pe.day == c.day else { continue }
                    }
                    // ★ 拼接 + 插值 -> 改成**一条带位置占位符**的整句。
                    //   %1$@ 这种位置标记是必须的:英文语序和中文不一样,
                    //   译文要能自由调换顺序而不改代码。
                    return Match(trade: t, leg: leg,
                                 reason: String(format: L("同一合约 %1$@ %2$@%3$@ · 该腿还有 %4$@ 未平"),
                                                sym, k.cleanNum, r == .call ? "C" : "P",
                                                abs(t.netQuantity(of: leg)).cleanNum))
                case .equity, .futures, .forex:
                    guard parsed.right == nil else { continue }   // 截图是期权,不能并进股票腿
                    return Match(trade: t, leg: leg,
                                 reason: String(format: L("同一标的 %1$@ · 还有 %2$@ 未平"),
                                                sym, abs(t.netQuantity(of: leg)).cleanNum))
                }
            }
        }
        return nil
    }

    /// 把解析出来的成交追加到指定腿上。**不修改 legs,只加 fill。**
    public static func appendFill(_ parsed: ParsedTrade, to trade: Trade, leg: Leg,
                                  underlying: Double? = nil, at time: Date) -> Trade? {
        guard let q = parsed.quantity?.value, let p = parsed.price?.value,
              let side = parsed.side?.value else { return nil }
        var t = trade
        let open = trade.netQuantity(of: leg)

        // ★★ 仓位截图给的是**整段**(开仓价 + 平仓价)。
        //   而要并进去的那一笔<b>开仓已经记过了</b> —— 再按 `parsed.price`(开仓价)
        //   追加一笔,就变成「又加了一次仓」,和用户看到的「没识别成平仓」是同一个病。
        //   ⇒ 这种情况只补**平仓那一笔**:反向、用平仓价、量不超过手上还有的。
        if let exit = parsed.exitPrice?.value, abs(open) > 1e-9 {
            let closing: Side = open > 0 ? .sell : .buy
            t.fills.append(Fill(legID: leg.id, time: time, side: closing,
                                quantity: min(q, abs(open)), price: exit, underlying: underlying,
                                // 平仓时刻仓位截图里通常没有 ⇒ 别编一个出来
                                timeIsEstimated: true))
            return t
        }

        t.fills.append(Fill(legID: leg.id, time: time, side: side,
                            quantity: q, price: p, underlying: underlying,
                            // ★ 截图没认出时间 ⇒ 这个 time 是调用方补出来的,不是事实
                            timeIsEstimated: parsed.time?.value == nil))
        return t
    }
}
