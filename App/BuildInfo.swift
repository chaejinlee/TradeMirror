import Foundation

/// 版本戳。**给「我到底装上新版没有」这个问题一个明确答案。**
///
/// 构建号由 `gen_xcodeproj.py` 在生成工程时写成 MMDDHHMM,
/// 所以它就是这个包被构建出来的时刻 —— 不需要手动维护。
enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    /// "v0.6 · 构建 09-01 12:03"
    static var stamp: String {
        let b = build
        guard b.count == 8 else { return "v\(version) · build \(b)" }
        let mm = b.prefix(2), dd = b.dropFirst(2).prefix(2)
        let HH = b.dropFirst(4).prefix(2), MM = b.suffix(2)
        return String(format: Loc.t("v%1$@ · 构建 %2$@-%3$@ %4$@:%5$@"),
                      version, String(mm), String(dd), String(HH), String(MM))
    }
}
