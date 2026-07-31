import SwiftUI
import AppKit
import Quartz

/// 右侧预览。直接用系统「快速查看」的渲染引擎（QLPreviewView），
/// 所以 PDF / 图片 / 视频 / 代码 / iWork 文档都跟按空格键预览是一个效果，
/// 不用自己给每种格式写渲染。
struct PreviewPane: NSViewRepresentable {
    var url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false      // 视频不要自动播放，会吵
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // 同一个文件不要反复 set —— 会让预览闪一下
        let current = (view.previewItem as? NSURL) as URL?
        guard current != url else { return }
        view.previewItem = url as NSURL?
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// 文件信息条（预览下面那行）
struct FileInfoStrip: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(hit.displayDirectory)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let meta = metaLine {
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var metaLine: String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: hit.path) else { return nil }
        var parts: [String] = []
        if let size = attrs[.size] as? NSNumber, (attrs[.type] as? FileAttributeType) != .typeDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))
        }
        if let date = attrs[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            parts.append(f.string(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
