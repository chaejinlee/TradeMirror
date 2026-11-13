import Foundation

/// 金额的写法。**全 App 只有这一种。**
///
/// ★ 放在引擎里而不是界面层:写法是纯逻辑,能测 —— 摆在视图里就又是一处没人测的判断。
///
/// ★★ 原来到处是 `.currency(code: "USD")` —— 中文区域下系统会写成 **`US$42`**。
///   在一个只有美元的 App 里,那两个字母只是噪音;券商(Wealthsimple)自己也写 `$4,839.99`。
/// ★ 负号用 U+2212(真正的减号):等宽数字里连字符会缩成一小截,和加号对不齐。
public enum Money {
    /// ★ 不用共享的 `NumberFormatter`:它不是线程安全的,而这里每次都要改小数位 ——
    ///   两个线程同时格式化就会串位。`FormatStyle` 是值类型,没有这个问题。
    private static func body(_ v: Double, _ d: Int) -> String {
        abs(v).formatted(.number.precision(.fractionLength(d))
                            .grouping(.automatic)
                            .locale(Locale(identifier: "en_US")))
    }

    /// `+$42` / `−$893` / `$0` —— 盈亏用这个。
    public static func signed(_ v: Double, decimals: Int = 0) -> String {
        let b = body(v, decimals)
        let isZero = b.allSatisfy { $0 == "0" || $0 == "." || $0 == "," }
        return (isZero ? "" : (v > 0 ? "+" : "−")) + "$" + b
    }

    /// `$42` / `−$893` —— 成本、净值这种没有「赚」的含义的数用这个(正数不带 +)。
    public static func plain(_ v: Double, decimals: Int = 0) -> String {
        (v < 0 ? "−" : "") + "$" + body(v, decimals)
    }

    /// 按美分取整。★ **比较、排序、取中位数之前先过一遍。**
    ///   浮点误差已经两次改了显示出来的结论:#179 一笔「正好 +$100」算成 100.000000000000227,
    ///   p 值从 0.55% 变成 0.38%;#189 一笔 $113 算成 112.99999999999997,中位盈 $121.50 显示成 $121。
    public static func cents(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// `+34.3%` / `−90.0%`。
    public static func pct(_ v: Double, decimals: Int = 1) -> String {
        let s = String(format: "%.\(decimals)f", abs(v * 100))
        let isZero = s.allSatisfy { $0 == "0" || $0 == "." }
        return (isZero ? "" : (v > 0 ? "+" : "−")) + s + "%"
    }
}

