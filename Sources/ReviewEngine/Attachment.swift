import Foundation

/// 贴在一笔交易上的图(通常是开仓时看到的图表)。
///
/// ★ 为什么值得做:用户截的图里 <b>2/3 是图表</b>(TradingView 标的图 / Webull 期权图),
/// 它们**没有成交明细**,做识别是白做 —— 但它们是「开仓那一刻我看到的东西」,
/// 正是复盘要回看的。配合规范 §2.7 的「原话」,这两样才是心理线索的载体。
///
/// **图存在 App 沙盒里,不上传、不联网**,与整体隐私定位一致。
public struct Attachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// 沙盒内的文件名(不是完整路径 —— 路径里含容器 UUID,重装后会变)。
    public var filename: String
    /// 用户自己写的一句话:「开仓时看到的 2 分图」。
    public var caption: String?
    public var addedAt: Date

    public init(id: UUID = UUID(), filename: String, caption: String? = nil, addedAt: Date = Date()) {
        self.id = id; self.filename = filename; self.caption = caption; self.addedAt = addedAt
    }
}

/// 附件文件的读写。**只存文件名,不存路径** ——
/// iOS 重装/迁移后 App 容器的 UUID 会变,存绝对路径的话图会全部失联。
/// 这是很多 App「换手机后图片全没了」的原因。
public final class AttachmentStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func `default`(fileManager: FileManager = .default) -> AttachmentStore {
        let docs = (try? fileManager.url(for: .documentDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return AttachmentStore(directory: docs.appendingPathComponent("attachments"))
    }

    public func url(for a: Attachment) -> URL { directory.appendingPathComponent(a.filename) }

    /// 写入。返回的 `Attachment` 才是要存进 Trade 的那个。
    @discardableResult
    public func save(_ data: Data, ext: String = "jpg", caption: String? = nil) throws -> Attachment {
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return Attachment(filename: name, caption: caption)
    }

    public func load(_ a: Attachment) -> Data? { try? Data(contentsOf: url(for: a)) }

    public func delete(_ a: Attachment) { try? FileManager.default.removeItem(at: url(for: a)) }

    /// 清掉没有被任何交易引用的孤儿文件。
    /// ★ 删交易时如果忘了删图,磁盘会一直涨 —— 这个在设置里手动跑,也在删交易时自动跑。
    @discardableResult
    public func pruneOrphans(referencedBy trades: [Trade]) -> Int {
        let live = Set(trades.flatMap { $0.attachments.map(\.filename) })
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var n = 0
        for f in all where !live.contains(f) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(f)); n += 1
        }
        return n
    }
}
