import Foundation

/// 备份文件夹里那一堆文件的**纯逻辑**:叫什么名、哪份最新、留几份。
///
/// ★★ 为什么单独拎出来:这三件事都可以写测试,而「选文件夹 / 写文件」那一层不能。
///   把能测的部分和不能测的部分分开 —— 这几天反复吃亏的就是
///   <b>判断住在没有测试的那一层</b>。
public enum BackupRotation {

    /// 每天一份:`复盘镜-2026-09-03.json`。
    /// ★ 和手动导出用**同一套命名**(`Exporter.filename`)——
    ///   两套命名意味着「最新的一份」会漏掉另一套里的文件。
    public static func fileName(for date: Date) -> String {
        Exporter.filename(ext: "json", now: date)
    }

    /// 从文件名里把日期抠回来。认不出返回 nil。
    ///
    /// ★ 不靠文件系统的修改时间:那个数会被同步、拷贝、还原改掉,
    ///   <b>而文件名里的日期是写下去那天的事实</b>。
    public static func date(fromFileName name: String) -> Date? {
        guard let r = name.range(of: #"(\d{4})-(\d{2})-(\d{2})"#, options: .regularExpression)
        else { return nil }
        let p = name[r].split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /// 认得出日期、**而且日期不在未来**的那些。「哪份最新」「该删哪些」都只看它们。
    ///
    /// ★★ 2026-10-03 在用户的 iCloud 备份文件夹里抓到一份 `复盘镜-4000-12-31.json`:
    ///   「立刻备份一次」为了绕过「今天写过了」,把 `now` 冒充成 `.distantFuture` ——
    ///   同一个 `now` 又被拿去起文件名、记「上次备份」(v3.7 起就这样,按一次覆盖一次)。
    ///   按文件名挑最新,这份就**永远最新**:重装后「找回」会一直拿它,
    ///   而它冻在最后一次按按钮的那一刻。
    ///   ⇒ 根子在 App 那层修了(那一层不再收 `now`);这里再挡一道,
    ///     因为**已经写出去的那份还在用户的 iCloud 里**,修好的 App 也得认出它是假的。
    /// ★ 留两天余量:文件名按**设备时区**起,人在亚洲时设备已经是明天了 —— 那份是真的。
    static func dated(_ names: [String], now: Date) -> [(String, Date)] {
        let horizon = now.addingTimeInterval(2 * 86_400)
        return names.compactMap { n -> (String, Date)? in
            guard let d = date(fromFileName: n), d <= horizon else { return nil }
            return (n, d)
        }
    }

    /// 一堆文件名里**最新的那一份**。
    ///
    /// ★ 只认得出日期的才参与 —— 认不出的宁可不选,也不要拿一个
    ///   不知道是什么时候的文件去覆盖用户当前的数据。日期在未来的同理(见 `dated`)。
    public static func latest(among names: [String], now: Date = Date()) -> String? {
        dated(names, now: now)
        .max { a, b in
            a.1 == b.1 ? a.0 < b.0 : a.1 < b.1     // 同一天多份时,名字大的算新
        }?.0
    }

    /// 保留最近 `keep` 天,返回**该删的**那些文件名。
    ///
    /// ★ 认不出日期的**一律不删**。删错文件是不可逆的,
    ///   而多留几个文件的代价只是几十 KB。
    /// ★ 日期在未来的也一样:不删,**也不占名额** —— 占一个就等于少留一天真的备份。
    public static func expired(among names: [String], keep: Int = 30,
                               now: Date = Date()) -> [String] {
        let dated = dated(names, now: now)
            .sorted { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }   // 新 → 旧
        guard dated.count > keep else { return [] }
        return dated.dropFirst(keep).map(\.0)
    }

    /// 今天这份备份写过了吗。
    ///
    /// ★ 按**交易所时区**判「今天」—— 和 App 里所有别的「今天」保持一致,
    ///   否则半夜过 12 点会莫名其妙多备一份、或者少备一份。
    public static func needsBackup(lastBackup: Date?, now: Date = Date()) -> Bool {
        guard let last = lastBackup else { return true }
        return TradingDay.key(of: last) != TradingDay.key(of: now)
    }
}

/// 备份**到底还活着没有**。
///
/// ★★ 2026-09-05 复盘查出来的:自动备份写的是
///   <code>_ = BackupVault.shared.backupIfNeeded { … }</code> —— <b>返回值直接丢掉。</b>
///   失败唯一的痕迹是数据页上「上次备份」那个日期不往前走,
///   而那一页是你**已经起疑**才会去看的。
///   于是「每天自动备份」可能已经好几天没成了,而你以为它开着。
///
/// ★ 这一层是纯逻辑,能写测试;界面只负责把它画出来。
///   同一个教训这个项目今年记过很多次:<b>摆在视图里的判断没人测。</b>
public enum BackupHealth: Sendable, Equatable {
    /// 还没选备份文件夹 —— 不算故障,别拿橙色吓人。
    case off
    /// 好着呢。
    case ok
    /// 上一次是失败的,带上系统原话。
    case failing(String)
    /// 没失败,但已经好几天没成过了(文件夹被搬走、iCloud 掉线都会这样)。
    case stale(days: Int)

    /// 要不要在主页上挂一条。★ 只有真出事才挂 —— 常驻提示等于没有提示。
    public var isAlarming: Bool {
        switch self { case .off, .ok: false; default: true }
    }

    public static func of(isConfigured: Bool, lastBackup: Date?, lastError: String?,
                          now: Date = Date(), staleAfterDays: Int = 3) -> BackupHealth {
        guard isConfigured else { return .off }
        // ★ 失败优先:哪怕昨天成功过,今天失败了也要说。
        if let e = lastError, !e.isEmpty { return .failing(e) }
        guard let last = lastBackup else { return .stale(days: staleAfterDays) }
        return daysApart(last, now) >= staleAfterDays ? .stale(days: daysApart(last, now)) : .ok
    }

    /// 隔了几个**日历日**(交易所时区)。★ 不是「几个 24 小时」——
    /// 昨天 23:50 到今天 00:10 是 1 天,不是 0 天。
    static func daysApart(_ a: Date, _ b: Date) -> Int {
        let cal = PeriodStats.cal
        return abs(cal.dateComponents([.day], from: cal.startOfDay(for: a),
                                      to: cal.startOfDay(for: b)).day ?? 0)
    }

    /// 给用户看的一句话。
    public func message(_ L: (String) -> String = { $0 }) -> String? {
        switch self {
        case .off, .ok: return nil
        case .failing(let why):
            return String(format: L("自动备份失败了:%@"), why)
        case .stale(let d):
            return String(format: L("自动备份已经 %d 天没成功过 —— 备份文件夹可能被搬走或删了"), d)
        }
    }
}
