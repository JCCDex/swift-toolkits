import SwiftUI

/// DID 头像二级全屏页（与 DApp 页同形态）：两个示例 DID 的头像，
/// 解析完成前显示 loading 效果，无头像/失败显示占位。
struct DidAvatarScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = DidAvatarService()

    var body: some View {
        NavigationView {
            List {
                ForEach(self.service.items) { item in
                    DidAvatarRow(item: item)
                }
            }
            .navigationTitle("DID 头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { self.dismiss() }
                }
            }
            .task {
                await self.service.start()
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct DidAvatarRow: View {
    let item: DidAvatarItem

    var body: some View {
        HStack(spacing: 12) {
            // 头像：本地图片文件已落库 → 直接出图（零 loading、不走网络）；
            // 否则 AsyncImage（下载中转圈）；无 URL 且解析中同样 loading。
            Group {
                if let path = self.item.localImagePath, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let url = self.item.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .failure:
                            PlaceholderView(icon: "photo")
                        default:
                            ProgressView() // 图片下载中
                        }
                    }
                } else if self.item.isLoading {
                    ProgressView() // DID/VC/元数据解析中
                } else {
                    PlaceholderView(icon: "person.crop.circle")
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(self.item.did)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = self.item.errorText {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PlaceholderView: View {
    let icon: String

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: self.icon)
                .foregroundColor(.secondary)
        }
    }
}
