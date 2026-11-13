import Foundation

/// 本地存储。
///
/// ★ 这个文件的每一条设计都对应一句竞品的真实差评(2026-08-30 抓取的 177 条):
///   「over half of my data got deleted by the app」
///   「all my trades got deleted」「Update reset my results」
///   「First day journaled trades, next day they were gone」
/// 数据丢失占差评 **29%**,是这个品类最大的失败模式。
///
/// 三条对策:
/// 1. **原子写入** —— 先写临时文件再 rename。写一半崩溃不会毁掉已有数据。
/// 2. **读不动时不覆盖** —— 解码失败就把坏文件改名留档并返回空,**绝不静默地用空数据覆盖**。
/// 3. **带版本号** —— 升级时能识别旧格式,而不是「Update reset my results」。
public struct StoreFile: Codable, Sendable {
    public var schemaVersion: Int
    public var trades: [Trade]
    /// 开仓前记下、还没对应到成交的计划。v5 新增。
    public var pendingPlans: [PendingPlan]
    /// 每日收盘价簿。v6 新增 —— 填一次,当天该标的全部交易共用。
    public var dailyCloses: DailyCloseBook
    /// 用户的硬规则。v7 新增。
    public var rules: TradingRules
    /// **没记进来的那些**。v14 新增 —— 看不见的漏记等于不存在。
    public var importFailures: [ImportFailure]
    /// 月度对账(券商上做了几笔)。v14 新增。
    public var reconciliations: [Reconciliation]
    /// 纪律手册。v15 新增。★ nil = 还没建过(第一次打开时种进去)。
    public var discipline: DisciplineBook?
    public init(schemaVersion: Int = TradeStore.currentSchemaVersion,
                trades: [Trade], pendingPlans: [PendingPlan] = [],
                dailyCloses: DailyCloseBook = .init(), rules: TradingRules = .init(),
                importFailures: [ImportFailure] = [],
                reconciliations: [Reconciliation] = [],
                discipline: DisciplineBook? = nil) {
        self.schemaVersion = schemaVersion; self.trades = trades
        self.pendingPlans = pendingPlans; self.dailyCloses = dailyCloses
        self.rules = rules
        self.importFailures = importFailures; self.reconciliations = reconciliations
        self.discipline = discipline
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, trades, pendingPlans, dailyCloses, rules
        case importFailures, reconciliations              // v14 才有
        case discipline                                   // v15 才有
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        trades = try c.decode([Trade].self, forKey: .trades)
        pendingPlans = try c.decodeIfPresent([PendingPlan].self, forKey: .pendingPlans) ?? []
        dailyCloses  = try c.decodeIfPresent(DailyCloseBook.self, forKey: .dailyCloses) ?? .init()
        rules        = try c.decodeIfPresent(TradingRules.self, forKey: .rules) ?? .init()
        importFailures = try c.decodeIfPresent([ImportFailure].self,
                                               forKey: .importFailures) ?? []
        reconciliations = try c.decodeIfPresent([Reconciliation].self,
                                                forKey: .reconciliations) ?? []
        discipline = try c.decodeIfPresent(DisciplineBook.self, forKey: .discipline)
    }
}

public enum StoreError: Error, Equatable {
    /// 文件存在但读不动。**带上备份路径** —— 用户的数据必须还在某个地方。
    case unreadable(backupPath: String)
    case futureSchema(found: Int, supported: Int)
}

public final class TradeStore: @unchecked Sendable {
    /// v3 = 加了 attachments。v1(单 instrument)/v2(无附件)都由 `Trade.init(from:)`
    /// 兼容读入,不会丢数据。
    public static let currentSchemaVersion = 15

    public let url: URL
    private let queue = DispatchQueue(label: "TradeStore")

    public init(url: URL) { self.url = url }

    /// 默认位置:App 的 Documents/trades.json(会进 iCloud 备份,用户也能自己导出)。
    public static func `default`(fileManager: FileManager = .default) -> TradeStore {
        let dir = (try? fileManager.url(for: .documentDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return TradeStore(url: dir.appendingPathComponent("trades.json"))
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// 读交易(兼容旧调用方)。
    public func load() throws -> [Trade] { try loadAll().trades }

    /// 读全部内容。文件不存在 → 空(全新安装)。坏了 → **抛错并已留档**,不返回空冒充成功。
    public func loadAll() throws
    -> (trades: [Trade], plans: [PendingPlan], closes: DailyCloseBook, rules: TradingRules,
        failures: [ImportFailure], recons: [Reconciliation], discipline: DisciplineBook?) {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: url.path)
            else { return ([], [], .init(), .init(), [], [], nil) }
            let data = try Data(contentsOf: url)
            do {
                let f = try Self.decoder.decode(StoreFile.self, from: data)
                guard f.schemaVersion <= Self.currentSchemaVersion else {
                    throw StoreError.futureSchema(found: f.schemaVersion,
                                                  supported: Self.currentSchemaVersion)
                }
                return (f.trades, f.pendingPlans, f.dailyCloses, f.rules,
                        f.importFailures, f.reconciliations, f.discipline)
            } catch let e as StoreError {
                throw e
            } catch {
                // 解码失败:把坏文件留档,**绝不当作空数据继续**
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("trades.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                throw StoreError.unreadable(backupPath: backup.path)
            }
        }
    }

    /// 写。**原子** —— 临时文件 + rename,中途崩溃不会留下半个文件。
    public func save(_ trades: [Trade]) throws { try save(trades, plans: [], closes: .init()) }

    public func save(_ trades: [Trade], plans: [PendingPlan],
                     closes: DailyCloseBook = .init(),
                     rules: TradingRules = .init(),
                     failures: [ImportFailure] = [],
                     recons: [Reconciliation] = [],
                     discipline: DisciplineBook? = nil) throws {
        try queue.sync {
            let data = try Self.encoder.encode(
                StoreFile(trades: trades, pendingPlans: plans,
                          dailyCloses: closes, rules: rules,
                          importFailures: failures, reconciliations: recons,
                          discipline: discipline))
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("trades.\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
    }
}
