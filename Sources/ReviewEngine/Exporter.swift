import Foundation

/// 导出 / 备份 / 导入。
///
/// ★ 这个文件的存在理由是一手数据,不是「大家都有所以我们也要有」:
///   216 条竞品 1–2 星差评里,**「数据丢失/无备份」占 5%,「无法导出」占 2%**。
///   原话:「7 months of data was deleted. Just simply gone.」
///
/// 而我们原本的形状**和它一模一样** —— 全部压在沙盒里一个 trades.json,
/// 还把「删掉 App 就全没了」当隐私卖点写在商店描述里。
/// 站在用户那边读,同一句话也是**风险声明**。
///
/// 两种导出,分工不同,**都需要**:
/// - **CSV** —— 给人看 / 进 Excel。可读,但**有损**(多腿、心理标签摊平了)。
/// - **备份文件(JSON)** —— 无损,**能原样导回来**。这才是「数据不被锁死」的真答案。
///   一个导不回去的导出不叫备份。
public enum Exporter {

    // ── CSV ──────────────────────────────────────────────────────────────

    /// 一行 = 一笔成交(不是一笔交易)。
    ///
    /// ★ 为什么按成交而不是按交易:一笔交易可以有多次加仓、分批平仓、多条腿。
    ///   按交易导出会**丢掉过程**,而过程正是复盘要看的东西。
    ///   想要按交易汇总,在 Excel 里对 trade_id 做透视即可 —— 反过来做不到。
    public static func csv(_ trades: [Trade]) -> String {
        // ★ 示例数据不进导出。备份是**用户的**数据,不该混进我编的那笔。
        let real = trades.filter { !$0.isSample }.sorted { $0.openTimeOrDistantPast < $1.openTimeOrDistantPast }

        var rows: [[String]] = [[
            "trade_id", "symbol", "strategy", "leg", "leg_kind", "leg_direction",
            "fill_time", "side", "quantity", "price", "multiplier", "cash_flow",
            "underlying", "is_closed", "realized_pnl", "avg_entry", "avg_exit",
            "psych_states", "psych_confidence", "psych_recorded_before_outcome",
            "note_entry", "note_exit", "exit_reason",
        ]]

        for t in real {
            let ordered = t.fills.sorted { $0.time < $1.time }
            for (i, f) in ordered.enumerated() {
                let leg = t.leg(for: f)
                let mult = t.multiplier(for: f)
                // ★ 交易级的数字**只写在该笔的第一行**,其余留空。
                //   否则用户在 Excel 里对 realized_pnl 求和会得到 N 倍的盈亏 ——
                //   那正是我们在竞品差评里骂的「算得不对」。
                let first = (i == 0)
                rows.append([
                    t.id.uuidString,
                    t.symbol,
                    t.strategy.rawValue,
                    leg.map { legIndexLabel(of: $0, in: t) } ?? "",
                    leg?.kind.shortLabel ?? "",
                    leg.flatMap { t.openingSide(of: $0) }.map { $0 == .buy ? "多" : "空" } ?? "",
                    iso(f.time),
                    f.side == .buy ? "buy" : "sell",
                    num(f.quantity),
                    num(f.price),
                    num(mult),
                    num(f.cashFlow(multiplier: mult)),
                    f.underlying.map(num) ?? "",
                    first ? (t.isClosed ? "yes" : "no") : "",
                    first ? (t.displayablePnL.map(num) ?? "") : "",   // 未平仓留空,不写 0
                    first ? num(t.averageEntry) : "",
                    first ? (t.isClosed ? num(t.averageExit) : "") : "",
                    first ? (t.psychology?.states.joined(separator: "|") ?? "") : "",
                    first ? (t.psychology.map { String($0.confidence) } ?? "") : "",
                    first ? (t.psychology.map { $0.beforeOutcome ? "yes" : "no" } ?? "") : "",
                    first ? (t.rawNoteAtEntry ?? "") : "",
                    first ? (t.rawNoteAtExit ?? "") : "",
                    first ? (t.exitReason ?? "") : "",
                ])
            }
        }

        // ★ BOM:没有它,Excel 打开中文备注是乱码。一个字节的事,不加就等着收差评。
        return "\u{FEFF}" + rows.map { $0.map(field).joined(separator: ",") }
                                .joined(separator: "\r\n") + "\r\n"
    }

    private static func legIndexLabel(of leg: Leg, in t: Trade) -> String {
        guard t.isMultiLeg, let i = t.legs.firstIndex(where: { $0.id == leg.id }) else { return "" }
        return "L\(i + 1)"
    }

    /// RFC 4180 转义 + 公式注入防护。
    static func field(_ s: String) -> String {
        var v = s
        // ★ CSV 注入:备注里以 = + - @ 开头的内容会被 Excel 当**公式**执行。
        //   备注是 OCR 出来的、也可能是券商文本,不能假定安全。
        //   只对文本列生效 —— 数字列由我们自己生成,不经过这里的危险分支。
        if let c = v.first, "=+-@\t\r".contains(c), Double(v) == nil {
            v = "'" + v
        }
        if v.contains(",") || v.contains("\"") || v.contains("\n") || v.contains("\r") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func num(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d.rounded())) }
        return String(format: "%.8f", d)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // ── 无损备份 ─────────────────────────────────────────────────────────

    /// 完整备份。**能导回来的那一种。**
    public static func backup(trades: [Trade], plans: [PendingPlan],
                              closes: DailyCloseBook, rules: TradingRules) throws -> Data {
        let file = StoreFile(trades: trades.filter { !$0.isSample },
                             pendingPlans: plans, dailyCloses: closes, rules: rules)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(file)
    }

    /// 建议文件名。带日期,因为用户会存好几份。
    public static func filename(ext: String, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "复盘镜-\(f.string(from: now)).\(ext)"
    }
}

/// 导入备份。
///
/// ★ 一条铁律:**导入永远不覆盖**。
///   竞品差评里最狠的一条是「Update reset my results」——
///   用户点一下就没了七个月的数据。所以这里只**合并**:
///   已存在的 id 一律跳过,并把跳过条数如实报给用户。
public enum Importer {

    public struct Report: Sendable {
        public var added: Int
        public var skipped: Int
        /// ★ 给**已存在**的交易补上的空字段数(v1.5 新增)。
        public var enrichedFields: Int = 0
        public var enrichedTrades: Int = 0
        public var trades: [Trade]
        public var rules: TradingRules?
        public var closes: DailyCloseBook?
    }

    public enum Failure: Error, Equatable {
        case notABackup
        case futureSchema(found: Int, supported: Int)
    }

    public static func read(_ data: Data) throws -> StoreFile {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let file = try? d.decode(StoreFile.self, from: data) else {
            throw Failure.notABackup
        }
        guard file.schemaVersion <= TradeStore.currentSchemaVersion else {
            throw Failure.futureSchema(found: file.schemaVersion,
                                       supported: TradeStore.currentSchemaVersion)
        }
        return file
    }

    /// 合并进现有数据。
    ///
    /// **同 id 的交易不会被替换** —— 但会**把你还空着的字段补上**。
    ///
    /// ★ 「补空」和「覆盖」是两件事,这里只做前者:
    ///   你自己填过的任何值一律不动,只填 nil。
    ///   起因是 v1.5 的 `tools/moomoo_enrich.py` —— 在电脑上用 moomoo 查到
    ///   期权的真实收盘价(手机 App 连不到 OpenD),再导回来。
    ///   若沿用「同 id 一律跳过」,补好的数据永远进不来。
    public static func merge(_ file: StoreFile, into existing: [Trade]) -> Report {
        var out = existing
        var index: [UUID: Int] = [:]
        // ★★ 2026-09-02 用户报「重新导入了,文件全部重复了」。
        //   原因:去重只看 `Trade.id`,而 id 是**我在导入脚本里造的**,每跑一次都不一样。
        //   我为了加「开单原因」重生成了一次文件 -> 5 笔变 10 笔。
        //   ⇒ 病根是「同一笔」的判据选错了:**UUID 相等太弱**。
        //     真正决定「是同一笔」的是<b>成交内容</b>(标的+合约+每笔成交)。
        //     所以这里同时按 id **和内容指纹**认人。
        var byPrint: [String: Int] = [:]
        for (i, t) in out.enumerated() {
            index[t.id] = i
            byPrint[t.fingerprint] = i
        }

        var added = 0, skipped = 0, fields = 0, touched = 0
        for t in file.trades where !t.isSample {
            guard let i = index[t.id] ?? byPrint[t.fingerprint] else {
                out.append(t)
                byPrint[t.fingerprint] = out.count - 1     // 同一批里也不许重复
                index[t.id] = out.count - 1
                added += 1
                continue
            }
            skipped += 1
            let before = fields
            // ★ 一律只在本地为 nil 时才填
            if out[i].finalUnderlying == nil, let v = t.finalUnderlying {
                out[i].finalUnderlying = v; fields += 1
            }
            if out[i].peakUnderlying == nil, let v = t.peakUnderlying {
                out[i].peakUnderlying = v; fields += 1
            }
            if out[i].peakTime == nil, let v = t.peakTime { out[i].peakTime = v; fields += 1 }
            if out[i].exitReason == nil, let v = t.exitReason { out[i].exitReason = v; fields += 1 }
            for (j, leg) in out[i].legs.enumerated() {
                // 腿也一样:id 是造的,合约才是真的。id 对不上就按**合约指纹**认。
                guard let src = t.legs.first(where: { $0.id == leg.id })
                        ?? t.legs.first(where: { $0.kind.fingerprint == leg.kind.fingerprint })
                else { continue }
                if leg.userClosePrice == nil, let v = src.userClosePrice {
                    out[i].legs[j].userClosePrice = v; fields += 1
                }
                // ★ 真实分钟路径也走「只补空」—— 它是 moomoo 补数据的主要载荷
                if (leg.path?.isEmpty ?? true), let v = src.path, !v.isEmpty {
                    out[i].legs[j].path = v; fields += 1
                }
            }
            if fields > before { touched += 1 }
        }
        return Report(added: added, skipped: skipped,
                      enrichedFields: fields, enrichedTrades: touched,
                      trades: out.sorted { $0.openTimeOrDistantPast < $1.openTimeOrDistantPast },
                      rules: file.rules, closes: file.dailyCloses)
    }
}

extension Trade {
    /// 排序用:没有成交时排到最前,不至于因为 nil 崩掉排序。
    var openTimeOrDistantPast: Date { fills.map(\.time).min() ?? .distantPast }
}
