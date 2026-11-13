import Foundation

/// 交易日归属。
///
/// ★ 这个文件存在的理由来自竞品的真实差评(2026-08-30 抓取的 177 条中反复出现):
///   「it started to shift my trades for ones taken on Monday to Sunday」
///   「I had pnl's on Saturdays and Sundays」
///   「entry and exit times are wrong. Maybe time zone issue」
/// 这是**跨 App 的同一个 bug**,根因都一样:用设备本地时区去归日期。
///
/// 本 App 的铁律:**交易日永远按交易所时区判定,不跟设备走。**
/// 用户飞到东京,他 8 月 6 日在纽约做的单,仍然属于 8 月 6 日。
public enum TradingDay {

    /// 交易所时区。美股统一 America/New_York(自动处理夏令时)。
    public static let exchangeTimeZone = TimeZone(identifier: "America/New_York")!

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = exchangeTimeZone
        return c
    }()

    /// 某个时刻所属的交易日(交易所时区的年月日)。
    public static func day(of date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// `YYYY-MM-DD`,交易所时区。存库与分组一律用它,不要用 `Date` 直接比较。
    /// `key(of:)` 的反向:"2026-09-01" → 那天纽约时间 12:00 的 Date。
    /// ★ 取 12:00 而不是 00:00 —— 午夜在夏令时切换日会掉到前一天。
    public static func date(fromKey key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        c.timeZone = exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)
    }

    public static func key(of date: Date) -> String {
        let c = day(of: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 是否周末。周末出现盈亏 = 时区归日期算错了,这是竞品最高频的可见症状。
    public static func isWeekend(_ date: Date) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return wd == 1 || wd == 7
    }

    /// 交易所时区的 `HH:mm`。
    ///
    /// ★★ 必须是**交易所时区**,不是手机时区。
    ///   用户 2026-09-03:「订单里面没显示具体开单时间」。
    ///   而一旦要显示时间,时区就成了正确性问题:同一笔 10:47 ET 的成交,
    ///   按多伦多时区显示还是 10:47,按北京时区显示就是**次日 22:47** ——
    ///   <b>日期都变了</b>。全 App 的归日、收盘价共用、周期分桶都按 ET,
    ///   显示也必须按 ET,否则屏幕上的时间和统计用的时间不是一回事。
    public static func clock(of date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

public extension Trade {
    /// 这笔交易属于哪个交易日 —— 按**首笔成交**的交易所时区日期。
    var tradingDayKey: String? {
        fills.min(by: { $0.time < $1.time }).map { TradingDay.key(of: $0.time) }
    }
    /// 自检:任何一笔成交落在周末,都说明数据录错或时区处理错了。
    var hasWeekendFill: Bool { fills.contains { TradingDay.isWeekend($0.time) } }

    /// 开仓时刻 = **首笔开仓成交**的时间。
    /// ★ 不是 `fills.min` —— 做空的首笔是卖出,拿「最早的成交」当开仓才对;
    ///   但如果有人先平后开(数据错乱),开仓时刻应该跟着**开仓方向**走。
    var entryTime: Date? {
        legs.flatMap { openingFills(of: $0) }.map(\.time).min()
    }
    /// 出场时刻 = **最后一笔平仓成交**的时间。未平仓返回 nil。
    var exitTime: Date? {
        let t = legs.flatMap { closingFills(of: $0) }.map(\.time).max()
        return isClosed ? t : nil
    }
    /// 交易所时区的开仓时刻 `HH:mm`。
    ///
    /// ★★ 时间是 App 填的默认值时**返回 nil** —— 不知道就说不知道。
    ///   用户 2026-09-03:「今天我添加的几笔全都是 11 点的时间点,但实际上不是」。
    ///   那个 11:00 是录入页的占位值;显示出来它就成了一条**假记录**。
    var entryClock: String? {
        let f = legs.flatMap { openingFills(of: $0) }.min { $0.time < $1.time }
        guard let f, !f.timeIsEstimated else { return nil }
        return TradingDay.clock(of: f.time)
    }
    /// 交易所时区的出场时刻 `HH:mm`。同上:估的不给。
    var exitClock: String? {
        guard isClosed,
              let f = legs.flatMap({ closingFills(of: $0) }).max(by: { $0.time < $1.time }),
              !f.timeIsEstimated else { return nil }
        return TradingDay.clock(of: f.time)
    }
    /// 有没有「时间是估的」的成交 —— 界面上要提示用户去补。
    var hasEstimatedTimes: Bool { fills.contains { $0.timeIsEstimated } }

    /// 疑似 v3.2 之前的**默认时刻**:所有成交都正好 11:00,而且都没被标成「估的」。
    ///
    /// ★ 那时录入页的默认时刻就是 11:00,但还没有 `timeIsEstimated` 这个标记,
    ///   所以分不出是占位值还是真成交。<b>只提示,不改数据</b> ——
    ///   直接当成占位值抹掉就是替用户断言,而我并不知道。
    /// ★ 判据只写在这一处,`Sanity` 和界面共用。
    var looksLikeLegacyDefaultTime: Bool {
        !fills.isEmpty && fills.allSatisfy {
            !$0.timeIsEstimated && TradingDay.clock(of: $0.time) == "11:00"
        }
    }

    /// **开仓**那几笔都是 11:00 —— 平仓可能是后来补的真时间。
    ///
    /// ★ 2026-10-03 分析「几点开仓最赚钱」时撞见的:9/3 那笔 719C,
    ///   两笔买入都是 11:00 占位,卖出 14:02 是修好之后录的真时间。
    ///   上面那条问的是「**所有**成交都 11:00 吗」,所以放过了它 ——
    ///   对它自己的问题没错;但对「几点开的仓」这个问题,它的开仓时间是假的。
    var entryLooksLikeLegacyDefaultTime: Bool {
        let opens = legs.flatMap { openingFills(of: $0) }
        return !opens.isEmpty && opens.allSatisfy {
            !$0.timeIsEstimated && TradingDay.clock(of: $0.time) == "11:00"
        }
    }
}

public extension TradingDay {
    /// 美股收盘时刻(交易所时区 16:00)。
    static func close(on date: Date) -> Date {
        var c = day(of: date); c.hour = 16; c.minute = 0; c.timeZone = exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c) ?? date
    }
    /// 从某时刻到到期日收盘,还有多少**自然小时**。
    /// 用它算出的 08-06 11:02 → 4.97 小时,与规范记录的 `hours_to_expiry` 完全一致。
    static func hoursToExpiry(from t: Date, expiryDay: Date) -> Double {
        max(close(on: expiryDay).timeIntervalSince(t) / 3600.0, 0)
    }
}
