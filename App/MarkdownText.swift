import SwiftUI

/// ★ 踩过的坑:`Text("... **粗体** ...")` 只有在**字符串字面量**时才走 LocalizedStringKey 从而解析 markdown。
/// 一旦用 `+` 拼接或传入 String 变量,就变成 `Text(String)`,`**` 会被原样显示出来。
/// 这个 helper 显式走 AttributedString,不依赖那条隐式规则。
extension Text {
    /// ★★ 2026-09-02:这里以前直接拿传进来的中文去解析 markdown,
    ///   **完全不经过本地化** —— App 里 39 处长句子全是它,一句都切不了语言。
    ///   现在先按 `Loc.bundle` 查一遍译文,查不到就用原文(= 中文)。
    ///   注意它**不能**靠 `Environment.locale`:`String(localized:)` 不看 environment,
    ///   只认传进去的 bundle。这是两条独立的路径,少接一条就半中半英。
    init(md: String) {
        let text = String(localized: String.LocalizationValue(md), bundle: Loc.bundle)
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // i18n-ok:AttributedString 那一路 —— 句子在上一行已经翻过了
        self = Text((try? AttributedString(markdown: text, options: opts))
                    ?? AttributedString(text))
    }
}

extension Double {
    /// 整数不显示小数点:3 → "3",1.5 → "1.5"
    var clean: String {
        self == rounded() ? String(Int(self)) : String(format: "%g", self)
    }

    /// 收益率:带符号的百分比。0.274 → "+27.4%",−0.5 → "−50.0%"
    ///
    /// ★ 负号用 U+2212(真正的减号),不是连字符 —— 等宽数字下连字符会缩成一小截。
    /// ★ 这里**不做本地化**:百分号和数字两种语言一样;
    ///   分母的含义由旁边那行标签负责说清楚。
    var signedPercent: String {
        String(format: self < 0 ? "−%.1f%%" : "+%.1f%%", abs(self * 100))
    }
}
