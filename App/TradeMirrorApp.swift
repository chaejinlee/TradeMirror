import SwiftUI

@main
struct TradeMirrorApp: App {
    var body: some Scene {
        // ★ 语言选择挂在根上 —— 换语言时整棵树重建(见 AppLanguageScope 的 .id)。
        //   不重建的话,`Text(md:)` / `Loc.t` 那一路不会自己去重新查译文。
        WindowGroup {
            RootView()
                .applyAppLanguage()
                // ★ 把翻译函数装进引擎。引擎默认是恒等函数(输出中文源文),
                //   所以 swift test 不需要 App 也能跑 —— **默认路径不依赖注入**。
                .task { EngineL10n.translate = { Loc.t($0) } }
        }
    }
}
