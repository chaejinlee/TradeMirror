import Foundation

/// 一次批量导入的**账**:选了几张、成了几张、少的那几张去哪了。
///
/// ★★ 存在的理由,一句话:<b>「我选了 8 张」这个数,从来没到过确认页。</b>
///
///   2026-09-04 用户选了 8 张截图,3 张的成交价没读出来。
///   确认页页头写的是「来自 N 张截图」,而那个 N 是**成功的那几张** ——
///   8 进 5 出,差额只有用户自己发现。他确实发现了,但那不该是他的活。
///
/// ★★ 这个类型守的是一条**会算术的**不变量:
///   <b>selected == 读不出 + 没认出字 + 字段不全 + 进了流程的。</b>
///   对不上就说明还有一条我没数到的静默路径 —— 那正是这次的病根:
///   `guard … else { continue }` 一共有三处,每一处都在把一张图变没,
///   而没有任何一处会留下痕迹。
public struct ImportTally: Sendable, Equatable {
    /// 用户在相册里选了几张。
    public var selected = 0
    /// 连图片都解不出来(文件坏了 / 格式不支持)。
    public var unreadable = 0
    /// OCR 一行字都没认出来。
    public var ocrEmpty = 0
    /// 认出了字,但核心字段太少,连配对都进不去。
    public var unusable = 0
    /// 进了配对流程的。
    public var accepted = 0

    public init(selected: Int = 0, unreadable: Int = 0, ocrEmpty: Int = 0,
                unusable: Int = 0, accepted: Int = 0) {
        self.selected = selected; self.unreadable = unreadable
        self.ocrEmpty = ocrEmpty; self.unusable = unusable; self.accepted = accepted
    }

    /// 没能进入流程的张数。
    public var dropped: Int { unreadable + ocrEmpty + unusable }

    /// ★★ 账对不对得上。
    ///   对不上 = 有一张图不知去向 = **代码里还有一条我没数到的静默路径**。
    ///   这条在测试里是硬断言,在界面上是一句给用户看的话 ——
    ///   <b>宁可承认「有 1 张不知去向」,也不要假装只选了 7 张。</b>
    public var balances: Bool { selected == dropped + accepted }

    /// 要不要在确认页上专门说一句。
    public var needsAttention: Bool { dropped > 0 || !balances }

    /// 一张截图的下场。**只有这四种**,而且必须恰好选一种。
    ///
    /// ★★ 把分支放在引擎里,是为了让「每张图恰好记一次」变成**结构上成立**,
    ///   而不是靠我在视图里的三个 `continue` 后面都记得加一行。
    ///   这次的病根就是那种「靠记得」的正确性 —— 三处 `continue`,
    ///   <b>每一处都在把一张图变没,而没有一处留下痕迹。</b>
    public enum Outcome: Sendable, Equatable {
        case unreadable, ocrEmpty, unusable, accepted
    }

    /// 一张图该算哪一种。★ 判据集中在这里,视图不再自己判。
    public static func outcome(imageLoaded: Bool, lines: [String],
                               parsed: ParsedTrade?) -> Outcome {
        guard imageLoaded else { return .unreadable }
        guard !lines.isEmpty else { return .ocrEmpty }
        // ★ 收下的门槛**故意比 `isUsable` 低**:只丢了价的那种要收进来,
        //   好让用户在确认页上手填补齐 —— 而不是在这里被无声地扔掉。
        guard let p = parsed, p.isUsable || p.symbol != nil else { return .unusable }
        return .accepted
    }

    /// 记一笔。★ 每张图**恰好**调一次,`balances` 就永远成立。
    public mutating func record(_ o: Outcome) {
        switch o {
        case .unreadable: unreadable += 1
        case .ocrEmpty:   ocrEmpty += 1
        case .unusable:   unusable += 1
        case .accepted:   accepted += 1
        }
    }

    /// 说给用户听的那句话。`nil` = 张数全对,不用打扰他。
    ///
    /// ★ 不写「导入成功」之类的空话 —— 只在**有差额**时出声。
    public func note(_ L: (String) -> String = { $0 }) -> String? {
        guard needsAttention else { return nil }
        var bits: [String] = []
        if unreadable > 0 { bits.append(String(format: L("%d 张打不开"), unreadable)) }
        if ocrEmpty > 0   { bits.append(String(format: L("%d 张没认出文字"), ocrEmpty)) }
        if unusable > 0   { bits.append(String(format: L("%d 张关键字段太少"), unusable)) }
        let missing = selected - dropped - accepted
        if missing != 0 { bits.append(String(format: L("%d 张不知去向"), abs(missing))) }
        return String(format: L("选了 %1$d 张,用上 %2$d 张 —— %3$@"),
                      selected, accepted, bits.joined(separator: "、"))
    }
}

// MARK: - 一张截图能不能变成一笔成交

extension ParsedTrade {

    /// 能不能变成一笔**成交**(`Fill`)。
    ///
    /// ★★ 和 `isUsable` 不是一回事,这一点正是 2026-09-04 那个 bug 的核心:
    ///   `isUsable` 还要求 `symbol` —— 而那三张的 `QQQ` 读得好好的,
    ///   只丢了价。于是它们**从「不可用」的网旁边走过去**,
    ///   进了草稿、显示在确认页上、最后在保存那一行被
    ///   <code>guard let px = … else { continue }</code> 静默扔掉。
    ///
    ///   <b>我建的是「整张图读不出」的网,真实故障是「读出来了但少一个字段」。</b>
    ///   两个阈值不重叠,故障就从缝里过去了。
    public var canBecomeFill: Bool {
        quantity != nil && price != nil && side != nil
    }

    /// 差哪几样。给界面直接显示,顺序固定。
    /// ★ 引擎里不许出现裸中文 —— 译文由调用方传进来(守卫会盯着这条)。
    public func fillBlockers(_ L: (String) -> String = { $0 }) -> [String] {
        var out: [String] = []
        if side == nil     { out.append(L("买卖方向")) }
        if quantity == nil { out.append(L("张数")) }
        if price == nil    { out.append(L("成交价")) }
        return out
    }
}

extension BatchImporter.Draft {

    /// 这一组里**存不进去**的那几张。
    public var unfillableParts: [ParsedTrade] { parts.filter { !$0.canBecomeFill } }

    /// 整组都能存。
    ///
    /// ★★ 界面必须拿这个来**挡住保存**,而不是存完拉倒。
    ///   少存一笔成交的后果不是「少一个数字」:
    ///   张数对不上 ⇒ `abs(netQuantity) < 1e-9` 不成立 ⇒ 这笔**永远未平仓**
    ///   ⇒ 未平仓不给盈亏(本 App 的规矩)⇒ <b>它从此不进胜率、不进热力图、
    ///   不进任何统计</b>。一笔亏损就这样从历史里消失了,而且不留痕迹。
    public var isComplete: Bool { unfillableParts.isEmpty }

    /// 用户在确认页手填补上一个价。★ 手填的 confidence 记 1.0 —— 那是他亲口说的。
    ///
    /// ★ **不动 `missing`**:那个数组是解析当时的快照,补完就过期了。
    ///   界面该按**当下的字段**算「还缺什么」(见 `fillBlockers`),
    ///   而不是读一份旧清单 —— 否则补好了还挂着「缺:成交价」。
    public mutating func fillInPrice(_ px: Double, atPartIndex i: Int, source: String = "") {
        guard parts.indices.contains(i), px > 0 else { return }
        parts[i].price = ParsedField(px, 1.0, source)
    }
}
