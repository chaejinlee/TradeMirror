import Foundation

/// 把 OCR 出来的**文本块**拼回**视觉行**。
///
/// ★ 存在的理由是一个实测 bug(2026-09-01):
/// 券商详情页是「标签在左、值在右」的表格,OCR 会把它们输出成**两个独立文本块**。
/// 只按纵坐标排序时,值和标签的 midY 只差 0.0008,谁在前**取决于浮点比较**——
/// 实测结果是「值在标签之前」,于是解析器读到「成交数量」后看下一行,
/// 拿到的是**下一行的值**(2.170 被当成了张数)。
///
/// 正确做法:**先按纵坐标分组成行,组内再按横坐标从左到右拼接。**
public enum LineAssembler {

    /// 一个 OCR 文本块。坐标用归一化值(0…1),原点左下(Vision 的约定)。
    public struct Block: Sendable {
        public var text: String
        public var midY: Double
        public var minX: Double
        public var height: Double
        public init(text: String, midY: Double, minX: Double, height: Double) {
            self.text = text; self.midY = midY; self.minX = minX; self.height = height
        }
    }

    /// 分行。`toleranceFactor` 乘以块高作为「算同一行」的纵向容差。
    /// 0.6 是实测值:太小会把同一行拆开,太大会把相邻行并在一起。
    /// - Parameter dropTopFraction: 丢掉顶部这一比例的内容(**手机状态栏**)。
    ///   ★ 真实截图里状态栏有:手机时间、指数报价、电量 —— 全都会污染解析
    ///   (实测:成交时间被读成状态栏的 10:56;纳斯达克指数 29172.20 进了数字池)。
    ///   合成图里永远不会有这些,所以这条只有拿真图测才会发现。
    public static func assemble(_ blocks: [Block], toleranceFactor: Double = 0.6,
                                dropTopFraction: Double = 0.035) -> [String] {
        guard !blocks.isEmpty else { return [] }
        let kept = blocks.filter { $0.midY < 1.0 - dropTopFraction }
        let sorted = (kept.isEmpty ? blocks : kept).sorted { $0.midY > $1.midY }   // 从上到下
        var rows: [[Block]] = []
        for b in sorted {
            let tol = max(b.height, 0.001) * toleranceFactor
            if var last = rows.last, let ref = last.first, abs(ref.midY - b.midY) <= tol {
                last.append(b); rows[rows.count - 1] = last
            } else {
                rows.append([b])
            }
        }
        return rows.map { row in
            row.sorted { $0.minX < $1.minX }                       // 组内从左到右
               .map(\.text)
               .joined(separator: "  ")
        }
    }
}


/// OCR 文本的通用清洗。
public enum OCRText {
    /// 去掉手机状态栏。
    ///
    /// ★ **只检查第一行。** 第一版我对每一行都判,结果把 `10:13 am` 这种
    /// 「只有时间」的合法成交时间行也杀了 —— 状态栏永远在最顶上,不该全局判。
    /// 真图里状态栏含:手机时间、指数报价、电量,全都会污染解析。
    public static func stripStatusBar(_ lines: [String]) -> [String] {
        guard let first = lines.first, isStatusBar(first) else { return lines }
        return Array(lines.dropFirst())
    }

    /// 修 OCR 在**数字里**的经典混淆:`$`→`S`、`0`→`O`、`1`→`l/I`。
    ///
    /// ★★ 2026-09-03 拿用户真图跑出来的:
    ///   `Filled quantity  10 × $0.12 USD` 被 OCR 成
    ///   <b>`10 × SO.12 USD`</b> —— `$` 成了 `S`,`0` 成了 `O`。
    ///   于是这一行**一个数都取不出来**,成交价为空,整张截图判成不可用。
    ///   用户看到的就是「没识别出来是平仓订单」。
    ///
    /// ★ 只动**看起来就是钱/数字**的 token(含数字、且只由数字和这几个易混字母组成),
    ///   别的一个字不碰 —— 否则 "USD"、"Sep"、"Call" 都会被改坏。
    public static func fixNumericConfusions(_ line: String) -> String {
        // ★★ 2026-09-04 用户的 8 张截图里有 3 张认不出成交价,共同点只有一个:
        //   <b>乘号和价格粘在一起</b> —— `1×$O.65`、`2 ×$O.32`、`3 ×$O.0733`。
        //   而带空格的 `5 × SO.13`、`9× $O.17` 都好好的。
        //   原因:这个函数原来**按空格切词**,只有「整个词看起来像数字」才修。
        //   `×$O.65` 是一个词,不像数字 ⇒ 那个 `O` 永远变不回 `0` ⇒ 取不出价。
        //   <b>OCR 加不加空格是随机的,而我把它当成了结构。</b>
        //   ⇒ 改成在**整行里找「像数字的那一段」**,不管它前后贴着什么。
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            guard let m = line.range(of: NUMERIC_RUN, options: .regularExpression,
                                     range: i..<line.endIndex) else {
                out += line[i...]; break
            }
            out += line[i..<m.lowerBound]
            let run = String(line[m])
            // ★★ 整段里**至少要有一个真数字**才动它 —— 否则 `SOLO`、`Ill`、`Total`
            //   这种纯字母也会被改坏。
            //   ⚠️ 判据必须落在**整段**上,不能落在「整数部分」上:
            //   `SO.12` 的整数部分是个字母 `O`,而它明明是 `$0.12`。
            //   (我第一版就写成了「整数部分必须有数字」,当场把 09-03 那张
            //    已经好了的截图弄坏 —— <b>夹具在同一分钟里抓住了我</b>。)
            out += run.contains(where: \.isNumber) ? repair(run) : run
            i = m.upperBound
        }
        return out
    }

    /// 「像一段数字」:可选的货币符号 + 一串数字或易混字母,中间可以有一个小数点。
    /// ★ 这里**故意放松**,让 `SO.12` / `$O.65` 这种整数部分全是字母的也能匹配;
    ///   「有没有真数字」在外面对**整段**判 —— 见上面那段注释。
    ///   `([.,][\dOolI]+)*` 是**星号**不是问号:`$1,234,567.00` 有两个分隔符,
    ///   只允许一个的话会被切成 `$1,234` + `,567.00` 两段,各自修一次 ⇒ 修不对。
    private static let NUMERIC_RUN = #"[$Ss]?[\dOolI]+([.,][\dOolI]+)*"#

    private static func repair(_ t: String) -> String {
        var out = ""
        for (i, ch) in t.enumerated() {
            switch ch {
            case "S", "s" where i == 0: out.append("$")
            case "O", "o":              out.append("0")
            case "l", "I":              out.append("1")
            case ",":                   out.append(",")     // 逗号留到下面统一处置
            default:                    out.append(ch)
            }
        }
        return fixCommas(out)
    }

    /// 逗号到底是**千位分隔符**还是**被认错的小数点**。
    ///
    /// ★★ 2026-09-15 用户 4 张真图,3 张的成交价取不出来。病根在这里:
    ///   原来 `,` 被**无条件**换成 `.`(为了修 OCR 把小数点认成逗号),
    ///   于是 <code>$2,200.00 → $2.200.00</code> —— 两个小数点,再也解析不出来。
    ///   <b>仓位小的时候金额到不了千位,这条永远碰不到。</b>
    ///   他现在做 20–29 张,总额动不动过千,它就全炸了。
    ///   ⇒ 这不是新写的 bug,是<b>一条一直存在、但要等仓位变大才会现形的 bug</b>。
    ///
    /// 判据(按顺序):
    ///   ① 整段里已经有 `.` ⇒ 逗号只能是千位分隔符 ⇒ 删掉
    ///   ② 逗号后面正好 3 位数字、且到段尾或下一个逗号 ⇒ 千位分隔符 ⇒ 删掉
    ///   ③ 其余(后面 1、2 位或 4 位以上)⇒ 被认错的小数点 ⇒ 换成 `.`
    static func fixCommas(_ t: String) -> String {
        guard t.contains(",") else { return t }
        // ① 已经有小数点 ⇒ 逗号统统是千位
        if t.contains(".") { return t.replacingOccurrences(of: ",", with: "") }

        let parts = t.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // ② 逗号之后的每一段都是 3 位数字(末段允许带尾随的非数字,如 `USD`)
        let tailsAreGroups = parts.dropFirst().allSatisfy { seg in
            seg.prefix(3).count == 3 && seg.prefix(3).allSatisfy(\.isNumber)
                && !(seg.dropFirst(3).first?.isNumber ?? false)
        }
        // ★ 千位分隔符前面那一段必须是 1…3 位数字,而且**不能以 0 开头** ——
        //   `0,257` 没人会写成「零千二百五十七」,那只能是 `0.257`。
        //   (这一条是实测逼出来的:`10 x $O,257` 原来被改成 `$0257`。)
        let head = parts[0].filter { $0.isNumber }
        let headIsThousands = (1...3).contains(head.count)
            && !(head.count > 1 && head.hasPrefix("0"))
            && head != "0"
        if tailsAreGroups && headIsThousands { return parts.joined() }
        // ③ 只有一个逗号、后面不是 3 位 ⇒ 当成小数点
        return t.replacingOccurrences(of: ",", with: ".")
    }

    static func isStatusBar(_ ln: String) -> Bool {
        guard ln.range(of: #"^\s*[01]?\d:[0-5]\d\b"#, options: .regularExpression) != nil
        else { return false }
        let l = ln.lowercased()
        let tradeWords = ["filled", "buy", "sell", "成交", "买", "卖", "qty", "price",
                          "order", "total", "avg", "quantity"]
        if tradeWords.contains(where: { l.contains($0) }) { return false }
        // ★★ 2026-09-03 真图实测:OCR 把 WiFi/电量图标认成了「今正」「今Z」,
        //   于是整行只剩 `15:44` 四个数字,旧判据(数字多于 4 个)**判不出来**,
        //   状态栏时间 15:44 就被当成了成交时间。
        //   ⇒ 补一条:**第一行**、纯 `HH:MM` 开头、<b>又没有 am/pm</b> 的,就是状态栏。
        //   合法的成交时间行几乎总带 am/pm(「10:13 am」「3:43pm」);
        //   而且这个判断只对第一行生效,成交时间不会排在最顶上。
        if ln.range(of: #"[ap]\.?m\.?"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return true
        }
        // 状态栏的特征:除了时间,还有别的数(指数/电量),或者带电量/信号图标文字
        let extraNums = (try? NSRegularExpression(pattern: #"\d"#))
            .map { $0.numberOfMatches(in: ln, range: NSRange(ln.startIndex..., in: ln)) } ?? 0
        return extraNums > 4          // "10:13 am" 只有 4 个数字字符 → 不算状态栏
    }
}
