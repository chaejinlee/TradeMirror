import Foundation

/// 到期时间的计量口径。
///
/// ★ 这个 enum 存在的唯一理由:口径搞错会让 0DTE 重定价全盘失真。
/// 用 2026-08-06 QQQ 717C 的真实成交反解验证过:
///   - `.tradingTime`  → IV 12.34%(规范记录的 12.0%,吻合)
///   - `.calendar`     → IV 28.54%(相差 2.4 倍)
/// 期权做市商对日内合约普遍按交易时间计时(周末与隔夜不消耗同等时间价值),
/// 故本引擎**默认 `.tradingTime`**。
public enum TimeBasis: String, Codable, Sendable {
    /// 252 交易日 × 6.5 小时/日。默认。
    case tradingTime
    /// 365 日历日 × 24 小时。仅供对照,不建议用于 0DTE。
    case calendar

    /// 把「距到期还有多少小时」换算成年化 T。
    public func years(hoursToExpiry h: Double) -> Double {
        switch self {
        case .tradingTime: return h / (6.5 * 252.0)
        case .calendar:    return h / (24.0 * 365.0)
        }
    }
}

public enum OptionRight: String, Codable, Sendable { case call, put }

/// Black–Scholes。0DTE 场景下 r 与 q 的影响远小于报价跳动,默认皆为 0。
public enum BlackScholes {

    /// 标准正态 CDF。
    @inlinable
    public static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    /// 期权理论价。`T` 已是年化时间;`T <= 0` 或 `sigma <= 0` 时退化为内在价值。
    public static func price(right: OptionRight,
                             spot S: Double, strike K: Double,
                             years T: Double, sigma: Double,
                             rate r: Double = 0.0) -> Double {
        guard T > 0, sigma > 0, S > 0, K > 0 else {
            let intrinsic = (right == .call) ? S - K : K - S
            return max(intrinsic, 0)
        }
        let vt = sigma * T.squareRoot()
        let d1 = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / vt
        let d2 = d1 - vt
        let disc = exp(-r * T)
        switch right {
        case .call: return S * normalCDF(d1) - K * disc * normalCDF(d2)
        case .put:  return K * disc * normalCDF(-d2) - S * normalCDF(-d1)
        }
    }

    /// 由市价反解隐含波动率。二分法 —— 比 Newton 慢,但**不会发散**,
    /// 而 0DTE 深度价内/价外时 vega 趋近 0,Newton 在那里非常不稳。
    /// 找不到解(市价低于内在价值或高于上界)时返回 `nil`,**不返回猜测值**。
    public static func impliedVolatility(right: OptionRight,
                                         spot S: Double, strike K: Double,
                                         years T: Double, price P: Double,
                                         rate r: Double = 0.0,
                                         lower: Double = 1e-4,
                                         upper: Double = 5.0,
                                         iterations: Int = 200) -> Double? {
        guard T > 0, P > 0 else { return nil }
        let intrinsic = max((right == .call) ? S - K : K - S, 0)
        guard P >= intrinsic - 1e-9 else { return nil }       // 市价低于内在价值:无解
        guard price(right: right, spot: S, strike: K, years: T, sigma: upper, rate: r) >= P
        else { return nil }                                    // 超出上界:无解
        var lo = lower, hi = upper
        for _ in 0..<iterations {
            let mid = (lo + hi) / 2
            if price(right: right, spot: S, strike: K, years: T, sigma: mid, rate: r) < P { lo = mid }
            else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
