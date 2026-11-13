import Foundation

/// 每日 / 每周 / 每月 / 每年的战绩。
///
/// ★★ 三条必须先说清楚的口径,否则这一栏就是个会骗人的数字:
///
/// ① **按「实现盈亏的那天」归期,不按开仓那天。**
///    8/31 开、9/2 平的单,盈亏是 9/2 兑现的,就归 9/2。
///    (`Trade.tradingDayKey` 用的是**首笔**成交,那是给「当天收盘价共用」用的,
///     和战绩不是同一个问题 —— 别复用错了。)
///
/// ② **交易所时区,不是手机时区。** 多伦多和纽约同区还好,
///    出差到别处一开 App,盘中的单会跳到前一天/后一天。
///
/// ③ **未平仓不进盈亏,但要单独报出来。**
///    否则你今天开了一张还没平,这一栏显示「$0 · 0 笔」——
///    读起来像「今天没交易」,而事实是「今天有一张在手」。
public enum StatsPeriod: String, CaseIterable, Sendable, Identifiable {
    case day, week, month, year
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .day:   return L("日")
        case .week:  return L("周")
        case .month: return L("月")
        case .year:  return L("年")
        }
    }
}

public struct PeriodBucket: Sendable, Identifiable, Equatable {
    public var id: String { key }
    /// 排序/去重用的稳定键:`2026-09-02` / `2026-W36` / `2026-09` / `2026`
    public var key: String
    /// 给人看的标签。
    public var label: String
    /// 图表 X 轴用的**短标签**。
    /// ★ App 侧以前是拿 `label` 做中文字符串替换(删「日」、「月」换成「/」)
    ///   —— 换英文之后那些替换全部落空,轴上会挤进完整日期。
    ///   短标签必须**自己算**,不能靠删字。
    public var shortLabel: String { Self.short(forKey: key) }

    /// ★ 从 key 算短标签。**空周期没有 bucket,但格子仍要有标签** ——
    ///   所以这一份实现必须能脱离 bucket 单独用。
    public static func short(forKey key: String) -> String {
        let p = key.split(separator: "-")
        if p.count == 2, p[1].hasPrefix("W") { return "W\(p[1].dropFirst())" }
        switch p.count {
        case 3:  return "\(Int(p[1]) ?? 0)/\(Int(p[2]) ?? 0)"
        case 2:  return String(format: L("%d 月"), Int(p[1]) ?? 0)
        default: return String(p[0])
        }
    }
    /// 这个周期的起点(交易所时区当地零点),用来排序。
    public var start: Date
    public var n: Int
    public var wins: Int
    public var pnl: Double
    /// 这个周期里还没平的单数。**不进盈亏,但要说。**
    public var openCount: Int
    /// 这个周期里「最好的**可执行**替代方案」比你多赚多少。
    /// 正 = 那样会更好(你少赚了);负 = 你的做法更好。nil = 算不出。
    /// ★ 「峰值出场」不参与 —— 它不可执行(`CFID.isExecutable`)。
    public var bestAlternativeDelta: Double?
    public var bestAlternativeLabel: String?

    public var winRate: Double { n > 0 ? Double(wins) / Double(n) : 0 }
}

public struct PeriodStats: Sendable {
    public var period: StatsPeriod
    /// **新的在前。**
    public var buckets: [PeriodBucket]
    /// 当前这个周期(今天 / 本周 / 本月 / 本年)。就算是 0 笔也会有,
    /// 因为「今天还没交易」本身就是要显示的信息。
    public var current: PeriodBucket

    /// ★★ 主页大号数字**该显示哪一格**。
    ///
    /// 实测(2026-09-02)踩到的设计问题:用户的数据全在 8 月,
    /// 切到「月」时当前月是 9 月、里面 0 笔 —— 于是整张卡显示「还没交易」,
    /// <b>而他要的「战绩」被压成了下面一根小条</b>。空周期把整张卡废掉了。
    ///
    /// ⇒ 当前周期有交易就显示它;没有就显示**最近一个有交易的周期**,
    ///   并由 `showingFallback` 告诉界面要标注「本月还没交易,这是最近有交易的月份」。
    ///   <b>不许悄悄换一格还假装是当前那格。</b>
    public var displayed: PeriodBucket {
        if current.n > 0 || current.openCount > 0 { return current }
        return buckets.first { $0.n > 0 || $0.openCount > 0 } ?? current
    }

    /// 大号数字显示的是不是「回退到最近有交易的那一格」。
    public var showingFallback: Bool { displayed.key != current.key }

    /// 小条要画的那些格(不含正在显示的那一格)。**新的在前。**
    public var strip: [PeriodBucket] {
        buckets.filter { $0.key != displayed.key && ($0.n > 0 || $0.openCount > 0) }
    }

    // ── 分桶 ─────────────────────────────────────────────────────────

    /// ★ 内部共用的日历(交易所时区 + 周一开始的 ISO 周)。
    /// 热力图也用它 —— 两套日历意味着「这一天算哪一周」会出现两个答案。
    public static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TradingDay.exchangeTimeZone
        c.firstWeekday = 2          // ★ 周一开始 —— 交易周不是从周日算的
        c.minimumDaysInFirstWeek = 4 // ISO-8601:第一周至少含 4 天
        return c
    }

    /// 这个时刻落在哪个桶里。返回 (键, 标签, 桶起点)。
    static func bucketOf(_ date: Date, _ period: StatsPeriod) -> (String, String, Date) {
        let c = cal
        switch period {
        case .day:
            let start = c.startOfDay(for: date)
            let d = c.dateComponents([.year, .month, .day], from: date)
            return (String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!),
                    String(format: L("%1$d 月 %2$d 日"), d.month!, d.day!), start)
        case .week:
            let d = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            let start = c.date(from: DateComponents(
                weekday: c.firstWeekday,
                weekOfYear: d.weekOfYear, yearForWeekOfYear: d.yearForWeekOfYear))
                ?? c.startOfDay(for: date)
            return (String(format: "%04d-W%02d", d.yearForWeekOfYear!, d.weekOfYear!),
                    String(format: L("第 %d 周"), d.weekOfYear!), start)
        case .month:
            let d = c.dateComponents([.year, .month], from: date)
            let start = c.date(from: DateComponents(year: d.year, month: d.month, day: 1))
                ?? c.startOfDay(for: date)
            return (String(format: "%04d-%02d", d.year!, d.month!),
                    String(format: L("%1$d 年 %2$d 月"), d.year!, d.month!), start)
        case .year:
            let y = c.component(.year, from: date)
            let start = c.date(from: DateComponents(year: y, month: 1, day: 1))
                ?? c.startOfDay(for: date)
            return (String(y), String(format: L("%d 年"), y), start)
        }
    }

    /// 挑出落在某一格里的交易。
    ///
    /// ★ 归期规则必须和 `compute` **完全一致**(已平按兑现日、未平按开仓日),
    ///   否则「按品种分类」加起来会和上面的大号数字对不上 ——
    ///   而用户第一眼就会看出来两个数不一样。
    ///   ⇒ 所以这里复用同一个 `bucketOf`,不另写一遍。
    public static func trades(_ trades: [Trade], in bucket: PeriodBucket,
                              period: StatsPeriod) -> [Trade] {
        trades.filter { t in
            guard !t.isSample,
                  let stamp = t.attributedAt
            else { return false }
            return bucketOf(stamp, period).0 == bucket.key
        }
    }

    public static func compute(_ trades: [Trade], period: StatsPeriod,
                               now: Date = Date()) -> PeriodStats {
        let real = trades.filter { !$0.isSample }

        struct Agg {
            var label = "", start = Date.distantPast
            var n = 0, wins = 0, open = 0
            var pnl = 0.0
            /// 每种可执行反事实在这个周期的累计 delta
            var deltas: [String: (label: String, sum: Double)] = [:]
        }
        var agg: [String: Agg] = [:]

        func slot(_ key: String, _ label: String, _ start: Date) -> Agg {
            var a = agg[key] ?? Agg()
            a.label = label; a.start = start
            return a
        }

        for t in real {
            // ★ 未平仓按**开仓日**归期(它还没实现盈亏,但它确实是那天开的)
            guard let stamp = t.attributedAt
            else { continue }
            let (key, label, start) = bucketOf(stamp, period)
            var a = slot(key, label, start)
            if !t.isClosed {
                a.open += 1
                agg[key] = a
                continue
            }
            a.n += 1
            let pnl = t.realizedPnL
            a.pnl += pnl
            if pnl > 0 { a.wins += 1 }
            if let fin = t.finalUnderlying {
                let r = CounterfactualEngine.allByTime(
                    trade: t, peakUnderlying: t.peakUnderlying,
                    peakTime: t.peakTime, finalUnderlying: fin)
                for cf in r.results
                where CFID(rawValue: cf.id)?.isExecutable ?? false {
                    var e = a.deltas[cf.id] ?? (cf.label, 0)
                    e.sum += cf.delta
                    e.label = cf.label
                    a.deltas[cf.id] = e
                }
            }
            agg[key] = a
        }

        func bucket(_ key: String, _ a: Agg) -> PeriodBucket {
            let best = a.deltas.values.max { $0.sum < $1.sum }
            return PeriodBucket(key: key, label: a.label, start: a.start,
                                n: a.n, wins: a.wins, pnl: a.pnl, openCount: a.open,
                                bestAlternativeDelta: best?.sum,
                                bestAlternativeLabel: best?.label)
        }

        var out = agg.map { bucket($0.key, $0.value) }.sorted { $0.start > $1.start }

        // 当前周期即使没有任何交易也要有一格 —— 「今天还没交易」也是信息
        let (ck, cl, cs) = bucketOf(now, period)
        let current = out.first { $0.key == ck }
            ?? PeriodBucket(key: ck, label: cl, start: cs, n: 0, wins: 0,
                            pnl: 0, openCount: 0,
                            bestAlternativeDelta: nil, bestAlternativeLabel: nil)
        if !out.contains(where: { $0.key == ck }) { out.insert(current, at: 0) }

        return PeriodStats(period: period, buckets: out, current: current)
    }
}

public extension Trade {
    /// 盈亏**兑现**的时刻 = 最后一笔平仓成交。未平仓返回 nil。
    ///
    /// ★ 和 `tradingDayKey`(首笔成交)刻意区分开:
    ///   「当天收盘价共用」问的是「这笔是哪天开的」,
    ///   「战绩」问的是「钱是哪天进来的」。**两个问题,两个答案。**
    var realizedAt: Date? {
        guard isClosed else { return nil }
        return legs.compactMap { closingFills(of: $0).last?.time }.max()
    }

    /// 这笔**归到哪一刻**:已平按兑现时刻,未平按开仓时刻。
    ///
    /// ★★ 这条规则原来在 `compute` 和 `trades(in:)` 里**各抄了一遍**,
    ///   2026-09-24 列表按天分组要用第三次 —— 三份迟早分叉,
    ///   一分叉就是「热力图写 +42 在 9/23,列表却把它排在 9/22」。
    ///   ⇒ 收成这一处。
    var attributedAt: Date? { isClosed ? realizedAt : fills.map(\.time).min() }
}
