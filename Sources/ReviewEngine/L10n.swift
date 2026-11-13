import Foundation

/// 引擎侧的本地化钩子。
///
/// ★★ 为什么是钩子而不是直接查表:**依赖方向是 App → Engine,反过来不行。**
///   引擎看不到 App 的 `Loc`,也不该知道 SwiftUI 的存在。
///   所以引擎只声明「我需要一个翻译函数」,由 App 在启动时装进来。
///
/// ★ 默认是**恒等函数** —— 也就是说没人装钩子时,引擎照样输出中文源文,
///   `swift test` 不受影响、不需要 App。**默认路径不能依赖注入是否发生。**
///
/// ★ 用法:所有**给人看的**格式模板都包一层 `L(...)`。
///   ⚠️ 三类不许包:
///     ① `StrategyKind` 的 rawValue、`Psychology.states` —— **存进 JSON 的**
///     ② `ScreenshotParser` 的匹配关键词 —— 那是认中文券商界面用的
///     ③ 注释
public enum EngineL10n {
    /// App 启动时装进来。★ `nonisolated(unsafe)`:只在启动时写一次,之后只读。
    nonisolated(unsafe) public static var translate: (@Sendable (String) -> String) = { $0 }
}

/// 简写。★ 故意起一个字母的名字 —— 162 处调用点,长名字会把代码撑烂。
@inlinable
public func L(_ key: String) -> String { EngineL10n.translate(key) }
