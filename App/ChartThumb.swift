import SwiftUI

/// 图表缩略图。点开看大图,长按(带 onDelete 时)可删。
struct ChartThumb: View {
    let store: AttachmentStore
    let attachment: Attachment
    var onDelete: (() -> Void)?
    @State private var full = false

    private var image: UIImage? { store.load(attachment).flatMap(UIImage.init(data:)) }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                // 文件丢了要说出来,不要显示一个空白方块
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("图丢了").font(.caption2)
                }.foregroundStyle(Theme.warn)
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .onTapGesture { if image != nil { full = true } }
        .contextMenu { if let onDelete { Button("删掉这张", role: .destructive, action: onDelete) } }
        .sheet(isPresented: $full) {
            if let img = image {
                NavigationStack {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: img).resizable().scaledToFit()
                    }
                    .navigationTitle(attachment.caption.map { Text(verbatim: $0) }
                                     ?? Text("开仓时的图"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { full = false } } }
                }
            }
        }
    }
}
