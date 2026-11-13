import Foundation

/// 仅 DEBUG:让自动化验证能直接打开某个界面并喂入已知数据。
///
/// 存在的理由很具体:Claude Code 的 iOS 模拟器**面板**需要 `sudo xcode-select`,
/// 在那之前只能用 `simctl` 截图、点不了屏幕。有这个钩子,界面就能被**自动验证**而不是靠人点。
/// Release 构建里整段不存在。
enum DebugHooks {
    static var args: [String] { ProcessInfo.processInfo.arguments }

    /// 「看个例子」用的示例交易 —— **Release 也要有**,所以放在 #if 之外。
    /// 数据是 2026-08-06 QQQ 717C 那笔真实交易(见 review_ai_spec.md)。
    static func sampleTrade() -> Trade {
        func t(_ hh: Int, _ mm: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 6
            c.hour = hh; c.minute = mm; c.timeZone = TradingDay.exchangeTimeZone
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        let leg = Leg(kind: .option(right: .call, strike: 717, expiry: t(16, 0)))
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg],
                     fills: [Fill(legID: leg.id, time: t(10,30), side: .buy,  quantity: 2, price: 2.17, underlying: 717.24),
                             Fill(legID: leg.id, time: t(10,47), side: .buy,  quantity: 1, price: 1.57, underlying: 716.45),
                             Fill(legID: leg.id, time: t(11, 2), side: .sell, quantity: 3, price: 2.51, underlying: 718.04)],
                     exitReason: "触及目标",   // i18n-ok:存档值,显示时按 key 翻
                     rawNoteAtEntry: Loc.t("价格看涨旗走出,并且在今日重要成交量分部位出现明显支撑。"),
                     peakUnderlying: 719.05, finalUnderlying: 715.56,
                     psychology: Psychology(states: ["有把握", "怕错过"], confidence: 4,
                                            plan: Loc.t("旗形突破就进,目标前高。"),
                                            beforeOutcome: true),
                     isSample: true)
    }

    #if DEBUG
    static var shouldSeedDemo: Bool { args.contains("--seed-demo") }
    static var shouldOpenReview: Bool { args.contains("--open-review") }
    static var shouldOpenSpread: Bool { args.contains("--demo-spread") }
    static var prefillPeak: String  { args.contains("--demo-spread") ? "721.00"
                                    : (args.contains("--prefill") ? "719.05" : "") }
    static var prefillClose: String { args.contains("--demo-spread") ? "722.00"
                                    : (args.contains("--prefill") ? "715.56" : "") }

    /// 已平仓的买入垂直价差:买 715C @4.00→5.50,卖 720C @1.80→2.60,各 2 张。
    /// 逐腿:买腿 +$300,卖腿 −$160,合计 +$140(与 MultiLegCounterfactualTests 里断言的一致)。
    static func demoSpread() -> Trade {
        func t(_ hh: Int, _ mm: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 6
            c.hour = hh; c.minute = mm; c.timeZone = TradingDay.exchangeTimeZone
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        let e = t(16, 0)
        let a = Leg(kind: .option(right: .call, strike: 715, expiry: e), note: "买 · 近端")
        let b = Leg(kind: .option(right: .call, strike: 720, expiry: e), note: "卖 · 远端")
        return Trade(symbol: "QQQ", strategy: .verticalSpread, legs: [a, b], fills: [
            Fill(legID: a.id, time: t(10, 0), side: .buy,  quantity: 2, price: 4.00, underlying: 716),
            Fill(legID: b.id, time: t(10, 0), side: .sell, quantity: 2, price: 1.80, underlying: 716),
            Fill(legID: a.id, time: t(14, 0), side: .sell, quantity: 2, price: 5.50, underlying: 719),
            Fill(legID: b.id, time: t(14, 0), side: .buy,  quantity: 2, price: 2.60, underlying: 719),
        // i18n-ok:exitReason 是存档值(显示时按 key 翻)
        ], exitReason: "触及目标",
           rawNoteAtEntry: Loc.t("看涨但不想付满价,用价差把成本压下来。"))
    }

    static func demoTrade() -> Trade { sampleTrade() }
    #else
    static var shouldSeedDemo: Bool { false }
    static var shouldOpenReview: Bool { false }
    static var shouldOpenSpread: Bool { false }
    static var prefillPeak: String { "" }
    static var prefillClose: String { "" }
    #endif
}
