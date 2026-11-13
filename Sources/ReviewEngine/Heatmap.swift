import Foundation

/// 战绩热力图:**一天一个小方格**,按周排成列。
///
/// ★ 为什么值得单独做一层纯逻辑:格子落在哪一列哪一行,是**日期算术** ——
///   而这个 App 的日期算术已经踩过三次(归日时区、周起点、夏令时)。
///   摆在引擎里能写测试;摆在视图里就又是一处没人测的判断。
///
/// ★ 行 = 周一…周五。周末不排 —— 美股不开盘,排出来就是五分之二的空白。
///   (要是以后加了加密货币,这里改成 7 行,别在视图里各写一套。)
public struct HeatmapCell: Sendable, Identifiable, Equatable {
    /// `2026-09-03`,交易所时区。
    public var key: String
    /// 这一天的交易所时区正午 —— 用来排序和显示,不参与归日。
    public var date: Date
    /// 1 = 周一 … 5 = 周五。**只在「日」的网格里有意义**,别的周期是 0。
    public var weekdayIndex: Int
    /// 给人看的标签:`9 月 3 日` / `第 36 周` / `2026 年 9 月` / `2026`。
    /// ★ 没交易的格子也要有标签 —— 点开之后总得知道这是哪一格。
    public var label: String
    /// 格子下面那行小字(`9/3` / `W36` / `9 月` / `2026`)。
    public var shortLabel: String
    /// 那天的统计。`nil` = **那天没有交易**(不是「盈亏为 0」)。
    public var bucket: PeriodBucket?
    /// 还没到的日子(这一周的后几天)。
    public var isFuture: Bool
    /// 就是今天。★ 界面要给它一个圈 —— 找不到「今天在哪」的日历不叫日历。
    public var isToday: Bool

    public var id: String { key }

    /// 格子里那个数字。**没有已实现盈亏就返回 nil** ——
    /// 未平仓、没交易的格子一个字都不写(空着比写个 0 诚实)。
    ///
    /// ★ 格子只有二三十个点宽,所以:不带货币符号、四位以上转成 `k`。
    ///   <b>写不下的数字等于没写</b>,挤成一团反而看不出哪天赚哪天亏。
    public var compactPnL: String? {
        guard hasRealizedPnL, let p = bucket?.pnl else { return nil }
        return Heatmap.compact(p)
    }

    /// 有没有已平仓的盈亏可显示。
    /// ★ 只有未平仓时返回 false —— 和 `displayablePnL` 同一个规矩:
    ///   持仓成本不是盈亏,不该染成红色。
    public var hasRealizedPnL: Bool { (bucket?.n ?? 0) > 0 }
}

public enum Heatmap {

    /// 按周分列的网格。**最早的一周在前**,每列自上而下是周一…周五。
    ///
    /// - Parameter weeks: 往回排几周(含本周)。
    public static func grid(buckets: [PeriodBucket], weeks: Int = 14,
                            now: Date = Date()) -> [[HeatmapCell]] {
        let cal = PeriodStats.cal
        let byKey = Dictionary(uniqueKeysWithValues: buckets.map { ($0.key, $0) })
        let today = cal.startOfDay(for: now)

        // 本周的周一
        guard let thisMonday = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let firstMonday = cal.date(byAdding: .weekOfYear, value: -(weeks - 1),
                                         to: thisMonday)
        else { return [] }

        return (0..<weeks).map { w -> [HeatmapCell] in
            guard let monday = cal.date(byAdding: .weekOfYear, value: w, to: firstMonday)
            else { return [] }
            return (0..<5).compactMap { d -> HeatmapCell? in
                guard let day = cal.date(byAdding: .day, value: d, to: monday) else { return nil }
                // ★ 用交易所时区的正午当代表时刻 —— 午夜在夏令时切换日会掉到前一天
                var c = cal.dateComponents([.year, .month, .day], from: day)
                c.hour = 12; c.timeZone = TradingDay.exchangeTimeZone
                guard let noon = Calendar(identifier: .gregorian).date(from: c) else { return nil }
                let key = TradingDay.key(of: noon)
                // ★★ 比**日期**,不比时刻。原来是 `noon > now`,而 noon 取的是当天 12:00 ——
                //   于是**上午打开 App 时,今天这一格会被当成「未来」画淡**(实测 0.35 透明)。
                //   <b>「是不是今天」是日期问题,不是时刻问题。</b>
                let todayKey = TradingDay.key(of: now)
                let (_, label, _) = PeriodStats.bucketOf(noon, .day)
                return HeatmapCell(key: key, date: noon, weekdayIndex: d + 1,
                                   label: label,
                                   shortLabel: PeriodBucket.short(forKey: key),
                                   bucket: byKey[key],
                                   isFuture: key > todayKey,
                                   isToday: key == todayKey)
            }
        }
    }

    /// 周 / 月 / 年的格子。**一个周期一格,最早在前,最后一格是当前周期。**
    ///
    /// ★ 用户 2026-09-03:「把周月年也能做成小格子」。
    /// ★ 和「日」不同,这里不排成日历 —— 周/月/年本来就是一维的,
    ///   摆成日历只会凭空多出一堆「不存在的格子」。
    /// ★ 空周期照样给格子:<b>「那个月一笔没做」也是信息</b>,
    ///   而且没有它,时间轴上会莫名其妙地缺一块。
    public static func cells(buckets: [PeriodBucket], period: StatsPeriod,
                             count: Int, now: Date = Date()) -> [HeatmapCell] {
        guard period != .day else { return grid(buckets: buckets, now: now).flatMap { $0 } }
        let cal = PeriodStats.cal
        let byKey = Dictionary(buckets.map { ($0.key, $0) }) { a, _ in a }
        let unit: Calendar.Component = switch period {
            case .week:  .weekOfYear
            case .month: .month
            default:     .year
        }
        let nowKey = PeriodStats.bucketOf(now, period).0
        var seen = Set<String>()
        return (0..<count).reversed().compactMap { i -> HeatmapCell? in
            guard let d = cal.date(byAdding: unit, value: -i, to: now) else { return nil }
            let (key, label, start) = PeriodStats.bucketOf(d, period)
            // ★ 按月往回退可能撞到同一个键(1/31 → 12/31 → 11/30…),去重
            guard seen.insert(key).inserted else { return nil }
            return HeatmapCell(key: key, date: start, weekdayIndex: 0,
                               label: label, shortLabel: PeriodBucket.short(forKey: key),
                               bucket: byKey[key],
                               isFuture: false, isToday: key == nowKey)
        }
    }

    /// 染色强度。**按这一段里的最大绝对值归一**,不按固定金额 ——
    /// 每个人的仓位大小差一个数量级,固定阈值对谁都不对。
    ///
    /// ★★ 2026-09-03 实测暴露的问题:原来是**连续**映射、下限 0.18 ——
    ///   赚 $100 而当期最大是 $261,算出来 0.38,<b>屏幕上几乎和空格一样淡</b>,
    ///   用户的原话是「今天的也没显示」。
    ///   ⇒ 改成**四级台阶**,最低一级 0.42:
    ///   <b>有交易的日子必须一眼看得出有交易</b>,深浅只用来分「大小」。
    ///   连续映射在数据学上更「精确」,但这张图的第一职责是**看得见**。
    public static func intensity(_ pnl: Double, maxAbs: Double) -> Double {
        guard maxAbs > 1e-9 else { return 0.42 }
        let r = min(1, abs(pnl) / maxAbs)
        switch r {
        case ..<0.25: return 0.42
        case ..<0.50: return 0.60
        case ..<0.75: return 0.80
        default:      return 1.0
        }
    }

    /// 小格子里能塞下的盈亏写法。
    ///
    /// ★ 负号用 U+2212(真正的减号)—— 等宽数字里连字符会缩成一小截。
    /// ★ 千位以上转 `k`:`1234` → `+1.2k`,`12345` → `+12k`。
    ///   格子宽度就那么点,<b>四位数会把两边的格子挤变形</b>。
    public static func compact(_ v: Double) -> String {
        let a = abs(v)
        // ★★ 先决定怎么写,再决定符号 —— 三个 bug 都出在这个顺序上(测试逼出来的):
        //   ① `0.4` 写成 `+0`(四舍五入之后是 0,却还挂着个加号)
        //   ② `9999` 写成 `10.0k`(六个字符,把两边的格子挤变形)
        //   ③ `1234567` 写成 `1235k`(百万级没有档位)
        let body: String
        switch a {
        case ..<1000:     body = String(Int(a.rounded()))
        case ..<9_950:    body = String(format: "%.1fk", a / 1000)      // ≤ 9.9k
        case ..<999_500:  body = String(format: "%.0fk", a / 1000)      // ≤ 999k
        case ..<9_950_000: body = String(format: "%.1fm", a / 1_000_000)
        default:          body = String(format: "%.0fm", a / 1_000_000)
        }
        // 写出来就是 0 的话不带符号 —— `+0` 是个自相矛盾的写法
        let isZero = body.allSatisfy { $0 == "0" || $0 == "." }
        let sign = isZero ? "" : (v > 0 ? "+" : (v < 0 ? "−" : ""))
        return sign + body
    }

    /// 这一段里最大的绝对盈亏 —— 染色的分母。
    public static func maxAbsPnL(_ grid: [[HeatmapCell]]) -> Double {
        maxAbsPnL(grid.flatMap { $0 })
    }
    public static func maxAbsPnL(_ cells: [HeatmapCell]) -> Double {
        cells.compactMap { $0.hasRealizedPnL ? abs($0.bucket?.pnl ?? 0) : nil }.max() ?? 0
    }

    /// 这一段的汇总:有交易的格子数、盈利格子数、总盈亏。
    /// ★ 分母是**有交易的那些格**,不是全部格 —— 没交易的周期不该拉低胜率。
    public static func summary(_ grid: [[HeatmapCell]])
    -> (days: Int, greenDays: Int, pnl: Double) {
        summary(grid.flatMap { $0 })
    }
    public static func summary(_ cells: [HeatmapCell])
    -> (days: Int, greenDays: Int, pnl: Double) {
        let c = cells.filter { $0.hasRealizedPnL }
        return (c.count, c.filter { ($0.bucket?.pnl ?? 0) > 0 }.count,
                c.reduce(0.0) { $0 + ($1.bucket?.pnl ?? 0) })
    }
}
