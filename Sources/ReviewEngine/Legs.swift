import Foundation

// MARK: - 腿(Leg)—— 一个仓位由若干条腿组成

/// 一条腿的品种。**乘数与最小跳动写在这里**,因为它们决定盈亏怎么算,不能让界面去猜。
public enum LegKind: Codable, Sendable, Equatable, Hashable {
    /// 股票 / ETF / 杠杆 ETF / 加密货币 —— 线性,乘数 1(加密可带小数张)。
    case equity
    /// 期权。
    case option(right: OptionRight, strike: Double, expiry: Date)
    /// 期货。`pointValue` = 每 1.0 点值多少钱(ES 50 · MES 5 · NQ 20 · MNQ 2)。
    case futures(contract: String, pointValue: Double, tickSize: Double)
    /// 外汇。`contractSize` = 一手多少单位(标准手 100,000 · 迷你 10,000 · 微型 1,000)。
    case forex(contractSize: Double)

    /// 报价 → 金额的换算系数。
    public var multiplier: Double {
        switch self {
        case .equity:                       return 1
        case .option:                       return 100
        case .futures(_, let pv, _):        return pv
        case .forex(let size):              return size
        }
    }

    public var isOption: Bool { if case .option = self { return true }; return false }

    /// 数量的单位。★ 2026-09-01 导入历史数据时露馅:一笔 467 股的 BEX
    /// 在列表里显示成「持 467 **张**」—— 张是期权/期货的单位。
    /// 单位说错不影响算,但会让人第一眼就觉得「这软件不懂我在交易什么」。
    public var unit: String {
        switch self {
        case .equity:  return "股"
        case .option:  return "张"
        case .futures: return "手"
        case .forex:   return "手"
        }
    }

    public var shortLabel: String {
        switch self {
        case .equity: return "股票/ETF"
        case .option(let r, let k, _):
            return "\(k.cleanNum)\(r == .call ? "C" : "P")"
        case .futures(let c, _, _): return c
        case .forex: return "外汇"
        }
    }
}

/// 常见期货合约的点值与最小跳动。**写死在代码里,不让用户填** ——
/// 填错点值会让整笔盈亏错一个数量级,而这些值是公开且固定的。
public struct FuturesContract: Sendable, Identifiable, Hashable {
    public let id: String          // 代码,如 "ES"
    public let name: String
    public let pointValue: Double
    public let tickSize: Double
    public var tickValue: Double { pointValue * tickSize }

    public static let all: [FuturesContract] = [
        .init(id: "ES",  name: "E-mini S&P 500",     pointValue: 50,   tickSize: 0.25),
        .init(id: "MES", name: "Micro E-mini S&P",   pointValue: 5,    tickSize: 0.25),
        .init(id: "NQ",  name: "E-mini Nasdaq 100",  pointValue: 20,   tickSize: 0.25),
        .init(id: "MNQ", name: "Micro E-mini Nasdaq",pointValue: 2,    tickSize: 0.25),
        .init(id: "YM",  name: "E-mini Dow",         pointValue: 5,    tickSize: 1.0),
        .init(id: "MYM", name: "Micro E-mini Dow",   pointValue: 0.5,  tickSize: 1.0),
        .init(id: "RTY", name: "E-mini Russell 2000",pointValue: 50,   tickSize: 0.10),
        .init(id: "M2K", name: "Micro Russell 2000", pointValue: 5,    tickSize: 0.10),
        .init(id: "CL",  name: "原油 Crude Oil",      pointValue: 1000, tickSize: 0.01),
        .init(id: "MCL", name: "Micro 原油",          pointValue: 100,  tickSize: 0.01),
        .init(id: "GC",  name: "黄金 Gold",           pointValue: 100,  tickSize: 0.10),
        .init(id: "MGC", name: "Micro 黄金",          pointValue: 10,   tickSize: 0.10),
    ]
    public static func find(_ code: String) -> FuturesContract? { all.first { $0.id == code } }
    public var legKind: LegKind { .futures(contract: id, pointValue: pointValue, tickSize: tickSize) }
}

/// 仓位里的一条腿。
public struct Leg: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: LegKind
    /// 展示用的名字。留空时用 `kind.shortLabel`。
    public var note: String?

    /// ★★ 收盘那一刻这条腿的**真实市场价**(用户填的)。v9 新增。
    ///
    /// 起因是用户 2026-09-01 的一句话:
    /// 「这个是末日期权,我这张 708 的 call 收盘的时候实际上只有 0.25」。
    ///
    /// 他说的对,而且指出了一个**我们算错了问题**的地方:
    /// 「若持有到收盘」和「若持有到到期」<b>是两个不同的数</b> ——
    /// 收盘时卖掉拿到的是**市场价**(0.25),放到到期拿到的是**内在价值**(0)。
    /// 我们一直算后者,标签却写着前者。<b>对 0DTE 这两个数差的就是全部。</b>
    ///
    /// 而历史期权价没有免费数据源(实测 Yahoo 过期链取不到,Polygon 期权要 $79/月),
    /// 所以:**模型给一个估算值,用户一眼能看到、能改;改了就当事实用。**
    public var userClosePrice: Double?

    /// 持仓期间这条腿的真实分钟路径。v10 新增,见 `PricePath.swift`。
    /// ★ 由 `tools/moomoo_enrich.py` 在电脑上取回来、随备份导入 —— App 自己不联网取它。
    public var path: [PriceBar]?

    public init(id: UUID = UUID(), kind: LegKind, note: String? = nil,
                userClosePrice: Double? = nil, path: [PriceBar]? = nil) {
        self.id = id; self.kind = kind; self.note = note
        self.userClosePrice = userClosePrice; self.path = path
    }
    public var display: String { note ?? kind.shortLabel }
}

// MARK: - 策略类型

/// 策略只是**标签 + 建腿模板 + 校验**,<b>不改变任何计算</b> ——
/// 盈亏与反事实一律由 legs + fills 算出来,不看这个枚举。
/// 这样即使用户选错了策略名,数字仍然是对的。
public enum StrategyKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case single            = "单腿"
    case verticalSpread    = "垂直价差"
    case calendarSpread    = "日历价差"
    case diagonalSpread    = "对角价差"
    case straddle          = "跨式"
    case strangle          = "宽跨式"
    case ironCondor        = "铁鹰"
    case ironButterfly     = "铁蝶"
    case butterfly         = "蝶式"
    case coveredCall       = "备兑开仓"
    case protectivePut     = "保护性看跌"
    case collar            = "领口"
    case ratioSpread       = "比例价差"
    case custom            = "自定义组合"

    public var id: String { rawValue }
    /// 这个策略预期有几条腿(用于录入时校验,不参与计算)。
    public var expectedLegCount: ClosedRange<Int> {
        switch self {
        case .single:                                  return 1...1
        case .verticalSpread, .calendarSpread,
             .diagonalSpread, .straddle, .strangle,
             .coveredCall, .protectivePut:             return 2...2
        case .ratioSpread:                             return 2...3
        case .butterfly:                               return 3...3
        case .collar:                                  return 3...3
        case .ironCondor, .ironButterfly:              return 4...4
        case .custom:                                  return 1...8
        }
    }
    public var isMultiLeg: Bool { expectedLegCount.upperBound > 1 }
}

extension Double {
    /// 717.0 → "717";717.5 → "717.5"
    var cleanNum: String { self == rounded() ? String(Int(self)) : String(format: "%g", self) }
}
