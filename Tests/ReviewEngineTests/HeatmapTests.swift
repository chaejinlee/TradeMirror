import XCTest
@testable import ReviewEngine

/// 战绩热力图的**日期算术**。
///
/// ★★ 为什么这一层必须有测试:格子落在哪一列哪一行全靠日期算术,
///   而这个 App 的日期算术已经踩过三次(归日时区、周起点、夏令时)。
///   <b>摆在视图里就又是一处没人测的判断。</b>
final class HeatmapTests: XCTestCase {

    private func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
        c.hour = h; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func bucket(_ key: String, pnl: Double, n: Int = 1, wins: Int = 1,
                        open: Int = 0) -> PeriodBucket {
        PeriodBucket(key: key, label: key, start: Date(), n: n, wins: wins,
                     pnl: pnl, openCount: open)
    }

    // ── 网格形状 ────────────────────────────────────────────────────

    func testGridIsWeeksOfFiveWeekdays() {
        let g = Heatmap.grid(buckets: [], weeks: 4, now: at(9, 3))
        XCTAssertEqual(g.count, 4, "4 周 = 4 列")
        XCTAssertTrue(g.allSatisfy { $0.count == 5 }, "每列周一…周五")
    }

    /// ★ 周末不排。美股不开盘,排出来就是五分之二的空白。
    func testWeekendsAreNotInTheGrid() {
        let g = Heatmap.grid(buckets: [], weeks: 2, now: at(9, 3))
        let cal = PeriodStats.cal
        for cell in g.flatMap({ $0 }) {
            let wd = cal.component(.weekday, from: cell.date)
            XCTAssertNotEqual(wd, 1, "\(cell.key) 是周日")
            XCTAssertNotEqual(wd, 7, "\(cell.key) 是周六")
        }
    }

    /// ★ 每一列都从**周一**开始 —— 交易周不是从周日算的。
    func testEachColumnStartsOnMonday() {
        let g = Heatmap.grid(buckets: [], weeks: 3, now: at(9, 3))
        let cal = PeriodStats.cal
        for col in g {
            XCTAssertEqual(cal.component(.weekday, from: col[0].date), 2, "第一行必须是周一")
            XCTAssertEqual(col[0].weekdayIndex, 1)
            XCTAssertEqual(col[4].weekdayIndex, 5)
        }
    }

    /// 最后一列包含今天。
    func testLastColumnContainsToday() {
        let now = at(9, 3)                       // 2026-09-03 是周四
        let g = Heatmap.grid(buckets: [], weeks: 6, now: now)
        let keys = g.last!.map(\.key)
        XCTAssertTrue(keys.contains("2026-09-03"), "最后一列应含今天,实际:\(keys)")
    }

    /// 本周还没到的日子标成 future(画淡一点),但**位置留着** ——
    /// 抽掉会让这一列比别的短,看起来像坏了。
    func testFutureDaysInThisWeekAreMarked() {
        let g = Heatmap.grid(buckets: [], weeks: 2, now: at(9, 3))   // 周四
        let last = g.last!
        XCTAssertFalse(last[3].isFuture, "周四就是今天")
        XCTAssertTrue(last[4].isFuture, "周五还没到")
    }

    /// ★★ 回归:**上午打开 App 时,今天不能被当成「未来」。**
    ///   原来是拿「当天 12:00」和 `now` 比 —— 早上 9 点打开,noon > now,
    ///   于是今天这一格被画成 35% 透明,用户看到的就是「今天的没显示」。
    ///   <b>「是不是今天」是日期问题,不是时刻问题。</b>
    func testTodayIsNeverFutureEvenInTheMorning() {
        for hour in [0, 6, 9, 12, 15, 23] {
            let g = Heatmap.grid(buckets: [], weeks: 1, now: at(9, 3, hour))
            let today = g.flatMap { $0 }.first { $0.key == "2026-09-03" }
            XCTAssertNotNil(today, "\(hour) 点时今天不在网格里")
            XCTAssertFalse(today!.isFuture, "\(hour) 点打开,今天不该算未来")
            XCTAssertTrue(today!.isToday, "\(hour) 点打开,今天就该标成今天")
        }
    }

    /// 只有一格是「今天」。
    func testExactlyOneCellIsToday() {
        let g = Heatmap.grid(buckets: [], weeks: 6, now: at(9, 3))
        XCTAssertEqual(g.flatMap { $0 }.filter(\.isToday).count, 1)
    }

    // ── 有没有交易 ──────────────────────────────────────────────────

    /// ★★ 这个 App 反复守的那条:**没交易 ≠ 盈亏为 0。**
    func testNoTradeIsDistinctFromZeroPnL() {
        let g = Heatmap.grid(buckets: [bucket("2026-09-03", pnl: 0)],
                             weeks: 2, now: at(9, 3))
        let cells = g.flatMap { $0 }
        let traded = cells.first { $0.key == "2026-09-03" }!
        let empty = cells.first { $0.key == "2026-09-02" }!
        XCTAssertTrue(traded.hasRealizedPnL, "有交易、盈亏 0 —— 仍然要染色")
        XCTAssertNil(empty.bucket, "没交易的那天 bucket 必须是 nil")
        XCTAssertFalse(empty.hasRealizedPnL)
    }

    /// 只有未平仓的那天 **不算**已实现盈亏 —— 持仓成本不是盈亏,不该染红。
    func testOpenOnlyDayHasNoRealizedPnL() {
        let g = Heatmap.grid(buckets: [bucket("2026-09-03", pnl: 0, n: 0, wins: 0, open: 2)],
                             weeks: 1, now: at(9, 3))
        let c = g.flatMap { $0 }.first { $0.key == "2026-09-03" }!
        XCTAssertNotNil(c.bucket)
        XCTAssertFalse(c.hasRealizedPnL)
        XCTAssertEqual(c.bucket?.openCount, 2)
    }

    // ── 染色 ────────────────────────────────────────────────────────

    /// 按这一段的最大绝对值归一 —— 每个人的仓位差一个数量级,固定阈值对谁都不对。
    func testIntensityIsRelativeToTheBiggestDay() {
        XCTAssertEqual(Heatmap.intensity(500, maxAbs: 500), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Heatmap.intensity(-500, maxAbs: 500), 1.0, accuracy: 1e-9,
                       "染多深看绝对值,红绿由正负决定")
        // 台阶:越大越深,但**不许倒挂**
        XCTAssertLessThanOrEqual(Heatmap.intensity(100, maxAbs: 500),
                                 Heatmap.intensity(300, maxAbs: 500))
    }

    /// ★★ 回归:用户 2026-09-03「今天的也没显示」——
    ///   当天 $100、当期最大 $261,旧的连续映射算出 <b>0.38</b>,
    ///   屏幕上几乎和空格一样淡。
    ///   <b>有交易的日子必须一眼看得出有交易。</b>
    func testAnyTradingDayIsClearlyVisible() {
        for (pnl, mx) in [(100.0, 261.0), (1.0, 100_000.0), (0.0, 0.0), (5.0, 261.0)] {
            XCTAssertGreaterThanOrEqual(Heatmap.intensity(pnl, maxAbs: mx), 0.42,
                                        "\(pnl)/\(mx) 淡到看不见了")
        }
        // 那个具体的例子:必须比原来的 0.38 明显更深
        XCTAssertGreaterThan(Heatmap.intensity(100, maxAbs: 261), 0.38)
    }

    func testMaxAbsIgnoresDaysWithoutTrades() {
        let g = Heatmap.grid(buckets: [bucket("2026-09-03", pnl: -300)],
                             weeks: 2, now: at(9, 3))
        XCTAssertEqual(Heatmap.maxAbsPnL(g), 300, accuracy: 1e-9)
    }

    // ── 汇总 ────────────────────────────────────────────────────────

    /// ★ 分母是**有交易的天数**,不是自然日 —— 没交易的日子不该拉低胜率。
    func testSummaryCountsOnlyTradingDays() {
        let g = Heatmap.grid(buckets: [bucket("2026-09-01", pnl: 100),
                                       bucket("2026-09-02", pnl: -40),
                                       bucket("2026-09-03", pnl: 250)],
                             weeks: 4, now: at(9, 3))
        let s = Heatmap.summary(g)
        XCTAssertEqual(s.days, 3)
        XCTAssertEqual(s.greenDays, 2)
        XCTAssertEqual(s.pnl, 310, accuracy: 1e-9)
    }

    /// 落在窗口之外的日子不参与汇总 —— 「最近 14 周」就得只算这 14 周。
    func testBucketsOutsideTheWindowAreIgnored() {
        let g = Heatmap.grid(buckets: [bucket("2026-01-05", pnl: 9999),
                                       bucket("2026-09-03", pnl: 10)],
                             weeks: 4, now: at(9, 3))
        XCTAssertEqual(Heatmap.summary(g).pnl, 10, accuracy: 1e-9)
        XCTAssertEqual(Heatmap.summary(g).days, 1)
    }

    /// ★ 夏令时切换那一周不许错位。2026-11-01 是美国改冬令时那天(周日)。
    func testDSTWeekKeepsFiveWeekdays() {
        let g = Heatmap.grid(buckets: [], weeks: 3, now: at(11, 5))
        XCTAssertTrue(g.allSatisfy { $0.count == 5 })
        let keys = g.flatMap { $0 }.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "不许出现重复的日子")
    }
}

/// 周 / 月 / 年的格子。用户 2026-09-03:「把周月年也能做成小格子」。
///
/// ★ 和「日」不同,这里是**一维时间轴**,不是日历 ——
///   所以测的是「有没有连续、有没有重复、最后一格是不是当前周期」。
final class PeriodCellTests: XCTestCase {

    private func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
        c.hour = h; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testWeekCellsAreContiguousAndEndOnThisWeek() {
        let cs = Heatmap.cells(buckets: [], period: .week, count: 26, now: at(9, 3))
        XCTAssertEqual(cs.count, 26)
        XCTAssertEqual(Set(cs.map(\.key)).count, 26, "不许有重复的周")
        XCTAssertTrue(cs.last!.isToday, "最后一格必须是当前这一周")
        // 时间递增 —— 最早在前
        XCTAssertTrue(zip(cs, cs.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    func testMonthCellsAreContiguousAndEndOnThisMonth() {
        let cs = Heatmap.cells(buckets: [], period: .month, count: 24, now: at(9, 3))
        XCTAssertEqual(Set(cs.map(\.key)).count, cs.count, "不许有重复的月")
        XCTAssertEqual(cs.last!.key, "2026-09")
        XCTAssertTrue(cs.last!.isToday)
    }

    /// ★ 按月往回退最容易撞车:从 31 号退一个月会落到 28/30 号。
    ///   这里从 3 月 31 日往回退,断言**每个月都在、且只出现一次**。
    func testSteppingBackFromThe31stDoesNotSkipOrRepeatMonths() {
        let cs = Heatmap.cells(buckets: [], period: .month, count: 6, now: at(3, 31))
        XCTAssertEqual(cs.map(\.key),
                       ["2025-10", "2025-11", "2025-12", "2026-01", "2026-02", "2026-03"])
    }

    func testYearCells() {
        let cs = Heatmap.cells(buckets: [], period: .year, count: 5, now: at(9, 3))
        XCTAssertEqual(cs.map(\.key), ["2022", "2023", "2024", "2025", "2026"])
        XCTAssertTrue(cs.last!.isToday)
    }

    /// ★ 空周期照样给格子 —— 「那个月一笔没做」也是信息,
    ///   而且缺一块会让时间轴莫名其妙地断开。
    func testEmptyPeriodsStillGetACell() {
        let cs = Heatmap.cells(buckets: [], period: .month, count: 3, now: at(9, 3))
        XCTAssertEqual(cs.count, 3)
        XCTAssertTrue(cs.allSatisfy { $0.bucket == nil })
        XCTAssertTrue(cs.allSatisfy { !$0.hasRealizedPnL })
    }

    /// 有 bucket 的那一格要接上,汇总也要对。
    func testBucketsAttachToTheRightCell() {
        let b = PeriodBucket(key: "2026-08", label: "2026 年 8 月", start: at(8, 1),
                             n: 4, wins: 4, pnl: 705, openCount: 0)
        let cs = Heatmap.cells(buckets: [b], period: .month, count: 3, now: at(9, 3))
        XCTAssertEqual(cs.first { $0.key == "2026-08" }?.bucket?.pnl, 705)
        let s = Heatmap.summary(cs)
        XCTAssertEqual(s.days, 1)
        XCTAssertEqual(s.pnl, 705, accuracy: 1e-9)
    }

    /// **每一格都要有标签** —— 没标签的方块等于没信息。
    func testEveryCellHasLabels() {
        for p in [StatsPeriod.week, .month, .year] {
            for c in Heatmap.cells(buckets: [], period: p, count: 4, now: at(9, 3)) {
                XCTAssertFalse(c.label.isEmpty, "\(p) 的 \(c.key) 没有标签")
                XCTAssertFalse(c.shortLabel.isEmpty, "\(p) 的 \(c.key) 没有短标签")
            }
        }
    }

    /// 「日」走原来的日历网格 —— 同一个入口别返回两种形状的东西。
    func testDayFallsBackToTheCalendarGrid() {
        let cs = Heatmap.cells(buckets: [], period: .day, count: 10, now: at(9, 3))
        XCTAssertEqual(cs.count, 14 * 5, "日 = 14 周 × 5 天的网格摊平")
    }
}

/// 格子里那个数字。用户 2026-09-03:「在小格子里显示盈亏金额」。
///
/// ★★ 这一层的约束不是「算得对」,是**「塞得下」** ——
///   格子只有二三十个点宽,<b>写不下的数字等于没写</b>,
///   还会把颜色挡住、把两边的格子挤变形。
final class HeatmapNumberTests: XCTestCase {

    private func at(_ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = m; c.day = d
        c.hour = 12; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testSignAndRounding() {
        XCTAssertEqual(Heatmap.compact(261), "+261")
        XCTAssertEqual(Heatmap.compact(-140), "−140")     // U+2212,不是连字符
        XCTAssertEqual(Heatmap.compact(0), "0", "持平不带正负号")
        XCTAssertEqual(Heatmap.compact(0.4), "0")
        XCTAssertEqual(Heatmap.compact(-0.4), "0", "四舍五入之后是 0,就别挂负号")
    }

    /// ★ 负号必须是真的减号 —— 等宽数字里连字符会缩成一小截。
    func testMinusIsTheRealMinusSign() {
        XCTAssertTrue(Heatmap.compact(-140).hasPrefix("\u{2212}"))
        XCTAssertFalse(Heatmap.compact(-140).hasPrefix("-"))
    }

    /// ★★ 四位数以上转 `k` —— 否则会把两边的格子挤变形。
    func testThousandsBecomeK() {
        XCTAssertEqual(Heatmap.compact(1234), "+1.2k")
        XCTAssertEqual(Heatmap.compact(-2574), "−2.6k")
        XCTAssertEqual(Heatmap.compact(-9999), "−10k", "进位到五位数要换档")
        XCTAssertEqual(Heatmap.compact(1_234_567), "+1.2m", "百万级要有档位")
        XCTAssertEqual(Heatmap.compact(12345), "+12k")
        XCTAssertEqual(Heatmap.compact(-123456), "−123k")
    }

    /// **写不下的不写**:任何金额的字符数都要压得住。
    func testEveryAmountStaysShort() {
        for v in [0.0, 7, -99, 999, 1000, -9999, 10_000, 999_999, -1_234_567] {
            XCTAssertLessThanOrEqual(Heatmap.compact(v).count, 5,
                                     "\(v) → \(Heatmap.compact(v)) 太长,格子里塞不下")
        }
    }

    /// ★★ 没有已实现盈亏的格子**一个字都不写** ——
    ///   空着比写个 0 诚实(没交易 ≠ 持平,未平仓 ≠ 盈亏 0)。
    func testCellsWithoutRealizedPnLShowNothing() {
        let g = Heatmap.grid(buckets: [
            PeriodBucket(key: "2026-09-02", label: "", start: at(9, 2),
                         n: 0, wins: 0, pnl: 0, openCount: 2),      // 只开了没平
        ], weeks: 2, now: at(9, 3))
        let cells = g.flatMap { $0 }
        XCTAssertNil(cells.first { $0.key == "2026-09-01" }?.compactPnL, "没交易 ⇒ 不写")
        XCTAssertNil(cells.first { $0.key == "2026-09-02" }?.compactPnL, "未平仓 ⇒ 不写")
    }

    /// 有交易、盈亏为 0 的那天**要写 0** —— 它和「没交易」不是一回事。
    func testZeroPnLDayStillShowsZero() {
        let g = Heatmap.grid(buckets: [
            PeriodBucket(key: "2026-09-02", label: "", start: at(9, 2),
                         n: 1, wins: 0, pnl: 0, openCount: 0),
        ], weeks: 2, now: at(9, 3))
        XCTAssertEqual(g.flatMap { $0 }.first { $0.key == "2026-09-02" }?.compactPnL, "0")
    }

    /// 周/月/年的格子也有数字。
    func testPeriodCellsCarryNumbersToo() {
        let cs = Heatmap.cells(buckets: [
            PeriodBucket(key: "2026-08", label: "", start: at(8, 1),
                         n: 4, wins: 4, pnl: 705, openCount: 0),
        ], period: .month, count: 3, now: at(9, 3))
        XCTAssertEqual(cs.first { $0.key == "2026-08" }?.compactPnL, "+705")
        XCTAssertNil(cs.first { $0.key == "2026-09" }?.compactPnL)
    }
}

/// OCR 在数字里的混淆修复 —— **不按空格切词**。
///
/// ★★ 用户 2026-09-04 发来 8 张截图,3 张认不出成交价。共同点只有一个:
///   <b>OCR 把乘号和价格粘在一起</b>(`1×$O.65` / `2 ×$O.32` / `3 ×$O.0733`),
///   而带空格的那几张都好好的。
///   旧实现按空格切词、要求「整个词像数字」—— 粘住的那一段不像,于是不修。
///   <b>OCR 加不加空格是随机的,而我把它当成了结构。</b>
final class NumericConfusionTests: XCTestCase {

    /// ★ 回归:三张失败截图里的原文,逐条钉住。
    func testGluedMultiplicationSignNoLongerHidesThePrice() {
        XCTAssertEqual(OCRText.fixNumericConfusions("Filled quantity  1×$O.65 USD"),
                       "Filled quantity  1×$0.65 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("Filled quantity  2 ×$O.32 USD"),
                       "Filled quantity  2 ×$0.32 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("Filled quantity  3 ×$O.0733 USD"),
                       "Filled quantity  3 ×$0.0733 USD")
    }

    /// 原来就好用的那几种写法**不许弄坏**。
    func testFormsThatAlreadyWorkedStillWork() {
        XCTAssertEqual(OCRText.fixNumericConfusions("10 x $O.257 USD"), "10 x $0.257 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("5 × SO.13 USD"), "5 × $0.13 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("9× $O.17 USD"), "9× $0.17 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("33 × $0.03 USD"), "33 × $0.03 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("3 × $1.22 USD"), "3 × $1.22 USD")
    }

    /// ★★ 纯字母**一个都不许动** —— 判据必须落在整段上,不是某一部分上。
    ///   (第一版把判据写在「整数部分」,当场把 `SO.12` 弄坏了 ——
    ///    它的整数部分是个字母 `O`,而它明明是 `$0.12`。)
    func testWordsAreNeverTouched() {
        for s in ["Total cost", "Sell to close", "Day order", "USD", "QQQ Sep 4 $721Call",
                  "SOLO", "Ill", "Options", "Status  Completed", "View QQQ options"] {
            XCTAssertEqual(OCRText.fixNumericConfusions(s), s, "不该动:\(s)")
        }
    }

    /// 逗号当小数点、开头的 S 当美元符号 —— 这两条也别退化。
    func testCommaAndLeadingS() {
        XCTAssertEqual(OCRText.fixNumericConfusions("S1,22"), "$1.22")
        XCTAssertEqual(OCRText.fixNumericConfusions("l0"), "10")
    }
}

/// Call / Put 判定 —— **两边各自计分,取高的**。
///
/// ★★ 2026-09-15 用户 4 张真图,3 张把 `$705 Put` 判成了 Call。
///   原来「callWords 先判、命中就定案」,而 callWords 里有 `" c "` ——
///   页面按空格连起来后出现 `…View trade confirmation C  Duplicate order S…`,
///   那个 `C` 是 <b>OCR 把「分享」图标认成的字母</b>。
///   <b>一个图标战胜了标题里明写着的 Put。</b>
final class JudgeRightTests: XCTestCase {

    /// ★★ 回归:把那 4 张图的真实 OCR 行原样摆进来。
    private let buyPageLines = [
        "11:402  •分⑤", "个", "QQQ Sep 15 $705 Put", "$2,200.00USD",
        "Account  Day Trading", "Status  Completeo",
        "Submitted  September 15, 2026", "10:38am",
        "Type  Market buy", "Buy to open", "Entered quantity  20",
        "Filled quantity  20 ×$1.10 USD", "Total cost  $2,200.00 USD",
        "View contract details -", "View QQQ options",
        "View trade confirmation C",           // ← 这个 C 是图标
        "Duplicate order S",                   // ← 它后面跟一个空格 ⇒ 凑出 " c "
    ]

    func testAnIconMisreadAsCDoesNotBeatTheWordPut() {
        let r = ScreenshotParser.judgeRight(buyPageLines)
        XCTAssertEqual(r?.value, .put,
                       "标题里写着 Put,不该被一个图标认出来的 C 压过去")
    }

    /// ★ 去掉最后那一行就「正好」变对 —— 说明原来的对错纯属巧合。
    ///   这条测试钉住的是:<b>页面末尾多一行少一行,结论不该变。</b>
    func testVerdictDoesNotDependOnWhetherAnExtraRowFollows() {
        let withRow = ScreenshotParser.judgeRight(buyPageLines)?.value
        let without = ScreenshotParser.judgeRight(Array(buyPageLines.dropLast()))?.value
        XCTAssertEqual(withRow, .put)
        XCTAssertEqual(without, .put)
        XCTAssertEqual(withRow, without, "结论跟着「末尾有没有多一行」变,就不叫判断")
    }

    /// 明写的词照常认。
    func testExplicitWords() {
        XCTAssertEqual(ScreenshotParser.judgeRight(["QQQ Sep 4 $721 Call"])?.value, .call)
        XCTAssertEqual(ScreenshotParser.judgeRight(["QQQ Sep 15 $705 Put"])?.value, .put)
        XCTAssertEqual(ScreenshotParser.judgeRight(["QQQ 看跌期权"])?.value, .put)
        XCTAssertEqual(ScreenshotParser.judgeRight(["认购 QQQ"])?.value, .call)
    }

    /// 贴着行权价的单字母算证据(`705C`),孤零零一个字母不算。
    func testOnlyLettersGluedToAStrikeCount() {
        XCTAssertEqual(ScreenshotParser.judgeRight(["QQQ 705C  10 张"])?.value, .call)
        XCTAssertEqual(ScreenshotParser.judgeRight(["QQQ 705 P  10 张"])?.value, .put)
        XCTAssertNil(ScreenshotParser.judgeRight(["View trade confirmation C  Duplicate order"]),
                     "一个没挨着数字的字母 = 图标或噪声,不该定案")
    }

    /// ★ 两边都有硬证据 ⇒ **不猜**。把 Put 记成 Call,盈亏和反事实全是反的。
    func testConflictingEvidenceReturnsNil() {
        XCTAssertNil(ScreenshotParser.judgeRight(["QQQ 705 Call", "QQQ 705 Put"]))
    }

    func testNoEvidenceReturnsNil() {
        XCTAssertNil(ScreenshotParser.judgeRight(["QQQ", "Day Trading", "Completed"]))
    }
}

/// 逗号:**千位分隔符**还是**被认错的小数点**。
///
/// ★★ 2026-09-15:`$2,200.00` 被改成 `$2.200.00` ⇒ 两个小数点 ⇒ 取不出价。
///   <b>这不是新写的 bug,是一条一直存在、但要等仓位变大才会现形的 bug</b> ——
///   仓位小的时候金额到不了千位,这条路永远走不到。
final class ThousandsSeparatorTests: XCTestCase {

    func testThousandsSeparatorsAreRemoved() {
        XCTAssertEqual(OCRText.fixNumericConfusions("Total cost  $2,200.00 USD"),
                       "Total cost  $2200.00 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("Total value  $4,843.00 USD"),
                       "Total value  $4843.00 USD")
        XCTAssertEqual(OCRText.fixNumericConfusions("+$1,236.00 return"), "+$1236.00 return")
        XCTAssertEqual(OCRText.fixNumericConfusions("$12,345 USD"), "$12345 USD")
    }

    /// ★ 多个分隔符:正则必须用 `*` 不是 `?`,否则被切成两段各修一次。
    func testMultipleSeparators() {
        XCTAssertEqual(OCRText.fixNumericConfusions("$1,234,567.00"), "$1234567.00")
    }

    /// 逗号当小数点的那些照旧对 —— 这是这条规则原本要修的东西,不许退化。
    func testCommaAsDecimalPointStillWorks() {
        XCTAssertEqual(OCRText.fixNumericConfusions("S1,22"), "$1.22")
        XCTAssertEqual(OCRText.fixNumericConfusions("1,5"), "1.5")
    }

    /// ★★ 千位分隔符**不可能跟在 0 后面** —— `0,257` 只能是 `0.257`。
    ///   (实测逼出来的:原来被改成 `$0257`,价格差了一千倍。)
    func testALeadingZeroMeansItIsADecimalPoint() {
        XCTAssertEqual(OCRText.fixNumericConfusions("10 x $O,257"), "10 x $0.257")
        XCTAssertEqual(OCRText.fixNumericConfusions("0,65"), "0.65")
    }

    /// 没有逗号的一律别动。
    func testUntouchedWhenNoComma() {
        for s in ["Total cost  $303.00 USD", "3 × $1.22 USD", "QQQ Sep 15 $705 Put"] {
            XCTAssertEqual(OCRText.fixNumericConfusions(s), s)
        }
    }
}

/// **OCR 吃掉空格**时关键词还认不认得出来。
///
/// ★★ 2026-09-23:系统从 Darwin 25 升到 27,Vision 换了模型,
///   同一张图上 `Buy to open` 变成了 `Buy toopen` ——
///   <b>三张已经绿了几周的夹具当场变红,而我一行代码都没改。</b>
///
/// ★★ 这和 2026-09-04 那个「乘号粘着价格」是**同一句话**:
///   <b>OCR 加不加空格是随机的,而我把它当成了结构。</b>
///   当时那条教训只用在了数字那一路,<b>词匹配这一路原样留着</b> ——
///   于是同一个坑三周后被一次系统升级重新踩开。
final class SpaceEatenOCRTests: XCTestCase {

    /// ★ 回归:升级后真实 OCR 吐出来的那一行。
    func testBuyToOpenSurvivesTheMissingSpace() {
        for ln in ["Buy toopen", "Buy to open", "Buytoopen", "BUY  TO  OPEN"] {
            XCTAssertEqual(ScreenshotParser.judgeIntent(["Type  Market buy", ln])?.value,
                           .open, "认不出:\(ln)")
        }
    }

    func testSellToCloseSurvivesToo() {
        for ln in ["Sell toclose", "Sell to close", "Selltoclose"] {
            XCTAssertEqual(ScreenshotParser.judgeIntent(["Type  Market sell", ln])?.value,
                           .close, "认不出:\(ln)")
        }
    }

    /// ★★ 「开仓均价」这种**字段名**仍然不算动作 —— 抽空格不能把这条规矩冲掉。
    ///   (这是 09-03 那个「一张平仓截图被判成买入」的病根。)
    func testFieldNamesStillDoNotCountAsActions() {
        XCTAssertNil(ScreenshotParser.judgeIntent(["开仓均价  2.170", "平仓均价  2.410"])?.value,
                     "字段名不是动作")
    }

    /// ★ 中文词**不抽空格** —— 中文本来不带空格,抽了反而会把「卖 出」误判进来。
    func testChineseIsMatchedAsIs() {
        XCTAssertEqual(ScreenshotParser.judgeIntent(["这一笔是平仓"])?.value, .close)
        XCTAssertEqual(ScreenshotParser.judgeIntent(["这一笔是开仓"])?.value, .open)
    }

    /// 工具函数本身。
    func testHelper() {
        XCTAssertTrue(ScreenshotParser.containsIgnoringSpaces("Buy toopen", "buy to open"))
        XCTAssertTrue(ScreenshotParser.containsIgnoringSpaces("BUYTOOPEN", "buy to open"))
        XCTAssertFalse(ScreenshotParser.containsIgnoringSpaces("Buy to closed", "buy to open"))
        // 中文原样比,不抽空格
        XCTAssertFalse(ScreenshotParser.containsIgnoringSpaces("开 仓", "开仓"))
        XCTAssertTrue(ScreenshotParser.containsIgnoringSpaces("这是开仓", "开仓"))
    }
}

/// 金额写法。★ 原来中文区域下会写成 `US$42` —— 只有美元的 App 里那两个字母是噪音。
final class MoneyFormatTests: XCTestCase {
    func testSigned() {
        XCTAssertEqual(Money.signed(42), "+$42")
        XCTAssertEqual(Money.signed(-893), "−$893")
        XCTAssertEqual(Money.signed(1649.4), "+$1,649")
        XCTAssertEqual(Money.signed(-1236.6), "−$1,237")
        XCTAssertEqual(Money.signed(41.69, decimals: 2), "+$41.69")
    }
    /// ★ 四舍五入之后是 0 就不挂符号 —— `+$0` 是自相矛盾的写法。
    func testZeroHasNoSign() {
        XCTAssertEqual(Money.signed(0), "$0")
        XCTAssertEqual(Money.signed(0.4), "$0")
        XCTAssertEqual(Money.signed(-0.4), "$0")
    }
    /// 负号是真正的减号 U+2212,不是连字符。
    func testRealMinusSign() {
        XCTAssertTrue(Money.signed(-5).hasPrefix("\u{2212}"))
        XCTAssertFalse(Money.signed(-5).hasPrefix("-"))
    }
    func testPlainHasNoPlus() {
        XCTAssertEqual(Money.plain(3607), "$3,607")
        XCTAssertEqual(Money.plain(-42), "−$42")
    }
    func testPct() {
        XCTAssertEqual(Money.pct(0.343), "+34.3%")
        XCTAssertEqual(Money.pct(-0.9), "−90.0%")
        XCTAssertEqual(Money.pct(0.0004), "0.0%")
        XCTAssertEqual(Money.pct(1.596, decimals: 0), "+160%")
    }
    /// ★ 不许出现 `US$` —— 这是这次改动的原因。
    func testNeverWritesUSDollarPrefix() {
        for v in [0.0, 42, -893, 1_234_567] {
            XCTAssertFalse(Money.signed(v).contains("US"))
            XCTAssertFalse(Money.plain(v).contains("US"))
        }
    }
}
