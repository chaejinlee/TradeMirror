import XCTest
@testable import ReviewEngine

/// **开发工具,不是测试。** 没设 `EXPORT_SRC` / `EXPORT_DEST` 时直接跳过。
///
/// 把手机上拷下来的 trades.json 用 **App 自己的解码器和引擎** 读一遍,
/// 导出一张逐笔表(盈亏、收益率、开平仓时刻)给外面做统计。
/// ★ 为什么不在 Python 里自己重算盈亏:两套算法迟早对不上 ——
///   这个项目已经在「同一件事写两遍」上栽过好几次。数字只从引擎出。
final class DevExportTests: XCTestCase {
    func testExport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["EXPORT_SRC"], let dest = env["EXPORT_DEST"] else {
            throw XCTSkip("开发工具:没设 EXPORT_SRC / EXPORT_DEST 就不跑")
        }
        let all = try TradeStore(url: URL(fileURLWithPath: src)).load()
        let iso = ISO8601DateFormatter()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TradingDay.exchangeTimeZone
        func clock(_ d: Date?) -> String {
            guard let d else { return "" }
            let c = cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        var rows = ["id,symbol,kind,is_sample,is_closed,open_at,close_at,open_clock,close_clock,"
                    + "weekday,pnl,ret,cost,n_fills,adds,exit_reason,time_estimated,legacy_time"]
        for t in all {
            let open = t.fills.map(\.time).min()
            let kind: String = {
                guard let k = t.primaryLeg?.kind else { return "?" }
                switch k { case .option: return "option"; case .equity: return "equity"; default: return "other" }
            }()
            let wd = open.map { cal.component(.weekday, from: $0) } ?? 0      // 1=周日
            let est = t.fills.contains { $0.timeIsEstimated }
            // ★ 旧版本没认出时间时填的 11:00 —— 用引擎自己的规则认,不在外面猜
            let legacy = Sanity.check(t).contains { $0.code == "legacy_default_time" }
            let reason = (t.exitReason ?? "").replacingOccurrences(of: ",", with: ";")
            rows.append([
                t.id.uuidString, t.symbol, kind, t.isSample ? "1" : "0", t.isClosed ? "1" : "0",
                open.map { iso.string(from: $0) } ?? "", t.realizedAt.map { iso.string(from: $0) } ?? "",
                clock(open), clock(t.realizedAt), "\(wd)",
                t.displayablePnL.map { String(format: "%.4f", $0) } ?? "",
                t.returnOnDebit.map { String(format: "%.6f", $0) } ?? "",
                String(format: "%.2f", t.netDebit), "\(t.fills.count)",
                "\(Distribution.addCount(t))", reason, est ? "1" : "0", legacy ? "1" : "0",
            ].joined(separator: ","))
        }
        try rows.joined(separator: "\n").write(toFile: dest, atomically: true, encoding: .utf8)
        let s = Distribution.summary(all)
        print("   ✅ 读到 \(all.count) 笔 · 已平 \(s.n) · 合计 \(Money.signed(s.total)) · 胜率 \(Int(((s.winRate ?? 0) * 100).rounded()))%")
    }
}
