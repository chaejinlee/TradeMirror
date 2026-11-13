import Foundation

/// 用**算术恒等式**认字段,而不是认标签。
///
/// ★ 为什么需要这一层:
/// 标签是每家券商一套(成交均价 / Avg Price / Fill Price / Preis …),
/// 靠词表匹配注定要一家一家加。**但数字之间的关系是普适的:**
///
///     张数 × 成交价 × 合约乘数 = 成交金额
///
/// 一张成交详情上出现 `2`、`2.170`、`434.00` 时,
/// 只有 (qty=2, price=2.17, mult=100) 这一组能让等式闭合 ——
/// **不看语言、不看版式、不看是哪家券商。**
///
/// 这一层不取代标签匹配,而是**给它打分**:
/// 恒等式闭合 → 置信度拉满;不闭合 → 降下来交给用户核对。
public enum NumericSolver {

    public struct Candidate: Sendable, Equatable {
        public var quantity: Double
        public var price: Double
        public var notional: Double
        public var multiplier: Double
        /// 等式两边的相对误差。0 = 完全闭合。
        public var relativeError: Double
        public var confidence: Double {
            // 1e-4 以内视作精确闭合(券商会四舍五入到分)
            relativeError <= 1e-4 ? 0.98 : max(0, 0.9 - relativeError * 40)
        }
    }

    /// 从一堆数字里找出能让 `qty × price × mult = notional` 闭合的组合。
    ///
    /// - Parameters:
    ///   - numbers: 页面上所有识别到的数(顺序无关)
    ///   - multipliers: 允许的乘数。期权 100,股票 1,期货点值各不相同 ——
    ///     **传进来而不是写死**,因为它本身就是待定的。
    /// - Returns: 按置信度降序;为空表示没有任何组合闭合(此时该退回标签匹配)。
    public static func solve(numbers: [Double],
                             multipliers: [Double] = [1, 100],
                             tolerance: Double = 0.02) -> [Candidate] {
        let ns = Array(Set(numbers.filter { $0 > 0 && $0.isFinite })).sorted()
        guard ns.count >= 3 else { return [] }
        var out: [Candidate] = []

        for q in ns {
            // 张数:正整数,且量级合理。0.5 张合约不存在;100 万股也基本不会出现在散户单上。
            guard q == q.rounded(), q >= 1, q <= 100_000 else { continue }
            for p in ns where p != q {
                guard p > 0, p < 1_000_000 else { continue }
                for m in multipliers {
                    let expect = q * p * m
                    guard expect >= 1 else { continue }
                    for n in ns where n != q && n != p {
                        let err = abs(n - expect) / max(expect, 1)
                        guard err <= tolerance else { continue }
                        // ★ 2026-10-05:500 × 32.2999 算出来是 16149.949999999999,误差 1e-16 ——
                        //   就因为这一丝,真解排在了「1 × 5 × 100 = 500」这种恰好为 0 的巧合后面。
                        //   1e-9 以下就是浮点噪声,一律当 0。
                        out.append(Candidate(quantity: q, price: p, notional: n,
                                             multiplier: m, relativeError: err < 1e-9 ? 0 : err))
                    }
                }
            }
        }
        // 去重 + 排序:误差小的优先;同误差时**乘数小的优先**;再同,**金额大的优先**。
        // ★ 2026-10-05 更正注释:这里原来写「乘数大的优先」,可代码一直是小的优先 ——
        //   认不出 Call/Put 时才会同时试 1 和 100,而那种页面多半是股票;两张股票夹具正是靠这个对的。
        // ★ 金额大的优先:真的成交金额是详情页上最大的那个钱数;
        //   巧合大多凑在小数上(SQQQ 那天:计时器的 1、日期里的 5、「500 shares」凑出 1 × 5 × 100 = 500)。
        var seen = Set<String>()
        return out
            .sorted { a, b in
                if a.relativeError != b.relativeError { return a.relativeError < b.relativeError }
                if a.multiplier != b.multiplier { return a.multiplier < b.multiplier }
                return a.notional > b.notional
            }
            .filter { c in
                let k = "\(c.quantity)|\(c.price)|\(c.multiplier)"
                return seen.insert(k).inserted
            }
    }

    /// 页面上出现的所有数字。**过滤掉明显不是金额/数量的东西**:
    /// 订单号(过长)、百分比、日期分量。
    public static func extractNumbers(from rawLines: [String]) -> [Double] {
        var out: [Double] = []
        // ★ 先剔状态栏:真图里的指数报价(29172.20)与电量(88)会凑出假恒等式。
        for ln in OCRText.stripStatusBar(rawLines) {
            // 先剔除日期与时间,否则 2026 / 08 / 06 / 10 / 30 会污染候选集
            // ★ 2026-10-05 补三条,都是那天 SQQQ 两张图里漏进来的:
            //   ① `October 5, 2026` 这种英文日期(原来只认 2026-10-05)—— 日期里的 5 进了候选
            //   ② `3:47pm` 不带空格 —— 原来时间后面要求词边界,`47p` 之间没有边界,3 和 47 都漏了
            //   ③ `1小时15分钟` —— 灵动岛里的计时器,1 和 15 都进了候选
            var s = ln
            for pat in [#"\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b"#,
                        #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?,?\s+\d{4}\b"#,
                        #"\b\d{1,2}:\d{2}(:\d{2})?(?!\d)"#,
                        #"\d+\s*(小时|分钟|秒钟|秒)"#,
                        #"(?i)\b\d+\s*(hours?|hrs?|minutes?|mins?)\b"#,
                        #"\b\d{6,}\b"#] {          // 订单号、YYMMDD
                s = s.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
            }
            // 百分比整段丢掉
            s = s.replacingOccurrences(of: #"-?\d[\d,]*\.?\d*\s*%"#, with: " ",
                                       options: .regularExpression)
            guard let re = try? NSRegularExpression(pattern: #"-?\d[\d,]*\.?\d*"#) else { continue }
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if let v = Double(ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")) {
                    out.append(v)
                }
            }
        }
        return out
    }
}
