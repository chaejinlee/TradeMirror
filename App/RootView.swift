import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            #if DEBUG
            if DebugHooks.shouldOpenSpread {
                ReviewView(trade: DebugHooks.demoSpread())
            } else if DebugHooks.shouldOpenReview {
                ReviewView(trade: DebugHooks.demoTrade())
            } else {
                TradeListView()
            }
            #else
            TradeListView()
            #endif
        }
    }
}
