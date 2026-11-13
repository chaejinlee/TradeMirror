import SwiftUI

/// App 内的语言选择。
///
/// ★★ 两条路径必须**都**切换,少一条就会出现半中半英:
///   ① `Text("字面量")` → 走 `LocalizedStringKey`,由 `Environment.locale` 决定
///   ② `Text(md:)` / `String(localized:)` → **不看 environment**,
///      只认传给它的 `Bundle`。所以必须显式把选中的 `.lproj` bundle 传进去。
///   我第一版只做了 ①,结果长句子(全是 md:)一句都不切 —— 见 `Loc.bundle`。
///
/// ★ 「跟随系统」是默认。用户没表达过偏好时,系统语言就是他的偏好。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", en

    var id: String { rawValue }

    /// 用**该语言自己**写自己的名字 —— 英文用户看到「简体中文」也认得出那是中文,
    /// 但看到「Chinese (Simplified)」才知道选的是什么。两个都给。
    var label: String {
        switch self {
        // i18n-ok:语言名按**各自的语言**写(英文选项就写 English),不该翻
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"   // i18n-ok:同上
        case .en:     return "English"
        }
    }

    /// 选它之后实际生效的语言代码。`system` 时交给系统决定。
    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en:     return "en"
        }
    }
}

enum Loc {
    /// 当前选择。★ 存在 UserDefaults —— 它是设备偏好,不是用户数据,
    /// 所以**不进备份文件**(导出/导入不该带着语言设置跑)。
    /// ★ 只有这一处知道 key 叫什么 —— 视图里的 `@AppStorage` 也用它。
    ///   两边各写一个字符串字面量,改一边就静默失联(今年踩过四次「同一张表两份副本」)。
    static let storeKey = "appLanguage"

    static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: storeKey) ?? "")
              ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storeKey) }
    }

    /// 给 `Environment.locale` 用 —— 管的是 `Text("字面量")` 这一路。
    static var locale: Locale {
        guard let id = current.localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: id)
    }

    /// 给 `String(localized:bundle:)` 用 —— 管的是 `Text(md:)` 那一路。
    ///
    /// ★ 找不到对应的 `.lproj` 就回退到主 bundle(= 显示中文源文),
    ///   **不崩、也不显示 key**。翻译没跟上时,宁可是中文。
    static var bundle: Bundle {
        guard let id = current.localeIdentifier,
              let path = Bundle.main.path(forResource: id, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }

    /// 显式查一条 —— 给那些不走 `Text` 的地方(引擎生成的句子、格式化模板)。
    static func t(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: bundle)
    }
}

/// 挂在根视图上的语言作用域。
///
/// ★★ 2026-09-03 用户报「切换语言之后软件内没有立刻转变」。
///   查下来:`TradeMirrorApp` 的注释写着「靠 `.id(langTick)` 整棵树重建」,
///   而旧的 `applyAppLanguage()` 里**只有 `environment(\.locale)`** ——
///   <b>那个 `.id` 我从来没写过</b>。注释描述的是意图,不是代码。
///
/// 两条路径的差别决定了这里必须有 `.id`:
///   · `Text("字面量")` 走 `environment(\.locale)` ⇒ locale 变了会自己重查
///   · `Text(md:)` / `Loc.t(…)` 在 **body 求值那一刻**就把字符串算完了,
///     它们**不读 environment** ⇒ 不重建视图就永远停在旧语言。
///
/// ★ `@AppStorage` 盯的就是 `Loc` 写的那把 key,所以选完立刻生效。
/// ★ 换语言会让整棵树重建 ⇒ 打开着的 sheet 会关掉。这是**有意的**:
///   那一下正好是「整个 App 已经换好」的反馈,而且 sheet 里没有未保存的输入。
private struct AppLanguageScope<Content: View>: View {
    @AppStorage(Loc.storeKey) private var lang = AppLanguage.system.rawValue
    let content: Content

    var body: some View {
        content
            .environment(\.locale, Loc.locale)   // ① Text("字面量") 这一路
            .id(lang)                            // ② Text(md:)/Loc.t 那一路
    }
}

extension View {
    /// 挂在根视图上。**两条路径一起切**。
    func applyAppLanguage() -> some View { AppLanguageScope(content: self) }
}


// MARK: - 引擎里那些「给人看的名字」

/// ★★ 引擎(ReviewEngine)**看不到** `Loc` —— 依赖方向是 App → Engine,反过来不行。
///   所以引擎里的展示名一律不在引擎里本地化,而是在这里做映射。
///
/// ★ 更重要的一条:`StrategyKind` 的 rawValue(「单腿」「铁鹰」)是**存进 JSON 的**,
///   `Psychology.states` 也是。<b>那些中文一个字都不能改</b> ——
///   改了旧存档读不出来、红旗判定失效。
///   ⇒ 存的是中文,显示的是译文。**两件事,两套字符串。**
extension StatsPeriod {
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .day:   return "日"
        case .week:  return "周"
        case .month: return "月"
        case .year:  return "年"
        }
    }
}

extension LegKind {
    /// 品种粗分类的译名。
    var localizedCategory: LocalizedStringKey {
        switch self {
        case .equity:  return "股票/ETF"
        case .option:  return "期权"
        case .futures: return "期货"
        case .forex:   return "外汇"
        }
    }
    /// 数量单位的译名(股 / 张 / 手)。
    var localizedUnit: String {
        switch self {
        case .equity:  return Loc.t("股")
        case .option:  return Loc.t("张")
        case .futures, .forex: return Loc.t("手")
        }
    }
}

extension StrategyKind {
    /// ★ rawValue 是存档用的,**不许翻**;这里只管显示。
    var localizedName: LocalizedStringKey { LocalizedStringKey(rawValue) }
}


// MARK: - 存档里存「格式 key + 数字」的那些,显示时才拼

extension Array where Element == String {
    /// 心理状态这类**存档中文数组**,逐个翻完再拼。
    /// ★ 整串拼好再翻是查不到的 —— 表里没有「追高 · 没耐心」这个 key。
    var localizedJoined: String { map { Loc.t($0) }.joined(separator: " · ") }
}


extension ImportFailure.Reason {
    /// ★ 说清楚**是哪一种没成**,而不是笼统一句「失败」——
    ///   三种的补救办法完全不同。
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .ocrEmpty:  return "一个字都没认出来"
        case .unusable:  return "认出了字但关键字段凑不齐"
        case .abandoned: return "打开了录入页,但没保存"
        }
    }
}
