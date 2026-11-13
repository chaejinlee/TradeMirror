import Foundation

/// 交易列表**按天分组**。
///
/// ★ 2026-09-24 美化时看截图看出来的:列表是 25 行一模一样的行,
///   **每行都重复完整日期**(`2026-09-03 11:05 → 11:40`),
///   看不出哪天赚哪天亏,也看不出一天做了几笔。
///   ⇒ 按天分组,组头写「9月3日 周四 · +$934 · 4 笔」,行里只留时刻。
///
/// ★★ 归到哪一天,和热力图用**同一条规则**(`Trade.attributedAt`):
///   已平按兑现日、未平按开仓日。否则就是「格子写 +42 在 9/23,列表却排在 9/22」。
public enum DayGroups {

    public struct Group: Sendable, Identifiable {
        /// `2026-09-03`,交易所时区。
        public var key: String
        /// 那天交易所时区的正午 —— 给界面格式化日期用。
        public var date: Date
        /// 这一天的交易,**新的在前**。
        public var trades: [Trade]
        public var id: String { key }

        /// 这一天兑现的盈亏。★ 只算已平仓、非样本 —— 和战绩卡片同一个口径。
        public var realized: Double {
            trades.filter { !$0.isSample }.compactMap(\.displayablePnL).reduce(0, +)
        }
        public var closedCount: Int { trades.filter { !$0.isSample && $0.isClosed }.count }
        public var openCount: Int { trades.filter { !$0.isSample && !$0.isClosed }.count }
    }

    /// 分组,**新的一天在前**。
    public static func group(_ trades: [Trade]) -> [Group] {
        var byKey: [String: [Trade]] = [:]
        for t in trades {
            guard let at = t.attributedAt else { continue }
            byKey[TradingDay.key(of: at), default: []].append(t)
        }
        return byKey.map { key, ts in
            Group(key: key, date: noon(of: key),
                  trades: ts.sorted { ($0.attributedAt ?? .distantPast) > ($1.attributedAt ?? .distantPast) })
        }
        .sorted { $0.key > $1.key }
    }

    /// `2026-09-03` → 那天交易所时区的正午。
    static func noon(of key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        if p.count == 3 { c.year = p[0]; c.month = p[1]; c.day = p[2] }
        c.hour = 12; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }
}
