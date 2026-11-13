import Foundation

/// **对账**:券商上这个月你做了几笔,App 里记了几笔。
///
/// ★★ 这是唯一能戳破「选择偏差」的办法。
///   2026-09-03 的事实:App 里 4 胜 0 负、100% 胜率,
///   而当天那笔 −$140 的亏损正好导入失败了。
///   <b>光看 App 内部的数,永远看不出自己漏了什么</b> ——
///   漏掉的那些按定义就不在里面。只能拿一个**外部的数**来对。
///
/// ★ 只要你自己填一个数(券商月结单上的笔数),剩下的都算得出来。
///   不联券商:那要账号密码,而这个 App 的前提是**不碰你的账户**。
public struct Reconciliation: Codable, Sendable, Equatable, Identifiable {
    /// `2026-09`,交易所时区。
    public var monthKey: String
    /// 券商上这个月**实际成交的笔数**(你自己看月结单填)。
    public var brokerTradeCount: Int
    public var notedAt: Date

    public var id: String { monthKey }

    public init(monthKey: String, brokerTradeCount: Int, notedAt: Date = Date()) {
        self.monthKey = monthKey
        self.brokerTradeCount = brokerTradeCount
        self.notedAt = notedAt
    }
}

/// 一个月的对账结果。
public struct ReconciliationResult: Sendable, Equatable {
    public var monthKey: String
    /// App 里这个月记了几笔(**按开仓日归月**,和券商月结单的口径一致)。
    public var recorded: Int
    /// 你填的券商笔数。没填就是 nil。
    public var broker: Int?
    /// 这个月导入失败了几次。
    public var importFailures: Int

    /// 差多少笔。券商数没填就算不了 —— **不猜**。
    public var gap: Int? { broker.map { $0 - recorded } }

    /// 差额里有多少能被「导入失败」解释掉。
    public var explainedByFailures: Int { min(gap ?? 0, importFailures) }

    public init(monthKey: String, recorded: Int, broker: Int?, importFailures: Int) {
        self.monthKey = monthKey; self.recorded = recorded
        self.broker = broker; self.importFailures = importFailures
    }
}

public enum ReconciliationEngine {

    /// 算某个月的对账。
    ///
    /// ★ 「App 里记了几笔」按**开仓日**归月(券商月结单也是按成交日列的),
    ///   而不是按盈亏兑现日 —— 那是 `PeriodStats` 的口径,两者不能混。
    ///   <b>口径不一样的两个数放在一起比,比不出任何东西。</b>
    public static func result(monthKey: String, trades: [Trade],
                              failures: [ImportFailure],
                              records: [Reconciliation]) -> ReconciliationResult {
        let recorded = trades.filter { t in
            guard !t.isSample, let first = t.fills.map(\.time).min() else { return false }
            return ImportFailure.monthKey(of: first) == monthKey
        }.count
        let broker = records.first { $0.monthKey == monthKey }?.brokerTradeCount
        let fails = failures.filter { ImportFailure.monthKey(of: $0.at) == monthKey }.count
        return ReconciliationResult(monthKey: monthKey, recorded: recorded,
                                    broker: broker, importFailures: fails)
    }

    /// 当前所属月份(交易所时区)。
    public static func currentMonthKey(_ now: Date = Date()) -> String {
        ImportFailure.monthKey(of: now)
    }
}

/// **什么时候该提醒你去对一次账。**
///
/// ★★ 这是 2026-09-22 复盘里最重要、也最不像功能的一条。
///   对账是<b>唯一能打破循环验证的东西</b> ——
///   在此之前我给这个 App 写的每一条「对上了」的测试,
///   用的都是**它自己导出来的数据**:OCR 读错一个数,导出里也是那个错数,测试照样绿。
///   而对账的记录数,到 2026-09-22 为止是 <b>0</b>。
///
///   同一天摊开的另一组数:08-03 → 09-15 之间有 32 个交易日,
///   App 里只有 11 天有记录,<b>08-07 → 08-27 连续 15 个交易日一笔都没有</b>。
///   是没做,还是没记?<b>没有券商那个数,谁也答不了。</b>
public enum ReconciliationPrompt {

    /// 一次提醒。`nil` = 现在不该打扰。
    public struct Ask: Sendable, Equatable {
        /// 要对的那个月,`2026-08`。
        public var monthKey: String
        /// App 里这个月记了几笔 —— 提示里直接写出来,省得他去数。
        public var recorded: Int
        /// 已经拖了几个月没对。
        public var monthsOverdue: Int
    }

    /// 该问哪个月。
    ///
    /// 规则:
    ///   ① 只问**已经结束的月份** —— 当月还没过完,券商月结单也还没出。
    ///   ② 只问**有记录的月份** —— 那个月一笔没做就没什么可对的。
    ///   ③ 已经填过的不再问。
    ///   ④ 一次只问**最早的那个** —— 一口气弹三个月没人会填。
    ///   ⑤ 往回最多看 `lookback` 个月 —— 半年前的月结单他多半也翻不到了。
    public static func next(trades: [Trade], records: [Reconciliation],
                            now: Date = Date(), lookback: Int = 6) -> Ask? {
        let cal = PeriodStats.cal
        let done = Set(records.map(\.monthKey))
        let thisMonth = ImportFailure.monthKey(of: now)

        // 有记录的月份(按开仓日归月,和券商口径一致)
        var counts: [String: Int] = [:]
        for t in trades where !t.isSample {
            guard let first = t.fills.map(\.time).min() else { continue }
            counts[ImportFailure.monthKey(of: first), default: 0] += 1
        }

        let candidates = counts.keys
            .filter { $0 < thisMonth }          // ① 当月不问
            .filter { !done.contains($0) }      // ③ 填过的不问
            .sorted()                           // ④ 先问最早的

        guard let m = candidates.first else { return nil }
        // ⑤ 太久远的不问 —— 翻不到的月结单,问了只会让人学会忽略提醒
        guard let cutoff = cal.date(byAdding: .month, value: -lookback, to: now),
              m >= ImportFailure.monthKey(of: cutoff) else { return nil }

        let overdue = candidates.count
        return Ask(monthKey: m, recorded: counts[m] ?? 0, monthsOverdue: overdue)
    }
}
