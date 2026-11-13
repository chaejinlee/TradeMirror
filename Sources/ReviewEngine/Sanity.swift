import Foundation

/// 录入体检。**在保存之前告诉用户「这个数不可能」和「这笔算不出东西」。**
///
/// ★★ 这个文件的起因是**第一份一手证据**:2026-09-01 用户导出的第一份真实备份里,
///    一笔 QQQ 期权写着 `strike = 402`,而标的价 707.73、权利金 1.34。
///    402 恰好等于 `3 × 1.34 × 100` —— **总金额被当成了行权价。**
///
///    更难堪的是:我有一个用「照抄那张真截图的文字」写的测试,断言 `strike == 708`,
///    **它一直是绿的**。测试测的是我的转录,不是真实链路。
///    ⇒ 教训:<b>绿测试不能代替对输出本身的体检。</b>
///    与其指望解析永远对,不如**在数据层面问一句「这可能吗」**。
public enum Sanity {

    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Level: Sendable, Equatable { case blocked, warn, info }
        public var id: String { code }
        public var code: String
        public var level: Level
        public var title: String
        /// 为什么不可能 / 缺什么。要能直接读懂,不要「校验失败」这种话。
        public var detail: String
    }

    /// 期权价**不可能低于内在价值** —— 这是无套利下界,和波动率、模型都无关。
    /// 低于它只有一种解释:某个数填错了。
    static func intrinsic(right: OptionRight, strike: Double, underlying: Double) -> Double {
        max(right == .call ? underlying - strike : strike - underlying, 0)
    }

    /// 检查一笔交易。`underlying` 取该腿首笔成交时记录的标的价(没有就跳过相关检查)。
    public static func check(_ t: Trade) -> [Finding] {
        var out: [Finding] = []

        for leg in t.legs {
            guard case .option(let right, let strike, _) = leg.kind else { continue }
            let fills = t.fills(of: leg)
            guard let first = fills.first else { continue }
            guard let u = first.underlying, u > 0 else { continue }
            let prem = first.price
            let iv = intrinsic(right: right, strike: strike, underlying: u)

            // ① 权利金低于内在价值 —— 无套利下界,不可能
            if prem < iv * 0.98 {
                // 这个数是不是恰好等于「总金额」?那是最常见的一种填错
                let notional = first.quantity * prem * leg.kind.multiplier
                let looksLikeNotional = abs(strike - notional) < 0.01
                out.append(Finding(
                    code: "strike_below_intrinsic",
                    level: .blocked,
                    title: L("这个行权价不可能"),
                    // ★ 原来是「拼接 + 插值 + 嵌套引号」——**根本不能当静态 key**
                    //   (运行时的 key 每次都不一样)。改成一条带位置占位符的整句。
                    //   `%1$@` 这种位置标记是必须的:英文语序和中文不同,
                    //   译文要能自由调换顺序而不用改代码。
                    detail: looksLikeNotional
                        ? String(format: L("行权价填的是 %1$@,而 %2$@ × %3$@ × %4$d = %5$@ —— **总金额被当成行权价了**。标的当时 %6$@,行权价 %1$@ 的 %7$@ 至少值 %8$@,不可能是 %3$@。"),
                                 strike.cleanNum, first.quantity.cleanNum, prem.cleanNum,
                                 Int(leg.kind.multiplier), notional.cleanNum, u.cleanNum,
                                 right == .call ? "call" : "put", iv.cleanNum)
                        : String(format: L("标的当时 %1$@,行权价 %2$@ 的 %3$@ 内在价值就有 %4$@,**期权价不可能低于内在价值**。现在填的是 %5$@。"),
                                 u.cleanNum, strike.cleanNum,
                                 right == .call ? "call" : "put", iv.cleanNum, prem.cleanNum)))
            }

            // ② 行权价离标的太远(> 50%),多半是少打或多打了一位
            if iv == 0, u > 0, abs(strike - u) / u > 0.5 {
                out.append(Finding(
                    code: "strike_far_from_underlying",
                    level: .warn,
                    title: L("行权价离标的很远"),
                    detail: String(format: L("标的 %1$@,行权价 %2$@ —— 差了 %3$d%%。确认没打错位?"),
                                   u.cleanNum, strike.cleanNum,
                                   Int(abs(strike - u) / u * 100))))
            }
        }

        // ③ ★ 已平仓、但缺了算反事实必需的数 —— 这笔存下来**一条分析都出不来**
        if t.isClosed, t.finalUnderlying == nil, t.peakUnderlying == nil {
            out.append(Finding(
                code: "no_counterfactual_input",
                level: .warn,
                title: L("这笔现在算不出任何替代路线"),
                detail: L("「持有到收盘会怎样」要**收盘时标的价**,「峰值出场」要**峰值时标的价**。两个都空着,这笔就只剩盈亏 —— 而盈亏你的券商 App 已经告诉你了。去复盘页顶上填一个,当天同标的的交易都能共用。")))
        }
        // ④ ★★ 老存档里的「11:00:00 整」—— v3.2 之前录入页的默认时刻就是它。
        //    那时还没有 `timeIsEstimated`,所以分不出是占位值还是真成交。
        //    <b>不改数据,只提一句</b> —— 说「这可能是默认值」是建议,
        //    直接把它当成默认值抹掉就是**替用户断言**,而我并不知道。
        if t.looksLikeLegacyDefaultTime {
            out.append(Finding(
                code: "legacy_default_time",
                level: .info,
                title: L("成交时刻正好都是 11:00"),
                detail: L("v3.2 之前录入页的默认时刻就是 **11:00** —— 这几笔很可能没填过时间。真是 11:00 成交就不用管;不是的话点「改」补上,**盈亏和所有统计都不受影响**,只是时刻显示会准。")))
        }
        return out
    }

    public static func blocking(_ t: Trade) -> [Finding] { check(t).filter { $0.level == .blocked } }
}
