import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ImageAttachmentGrid: View {
    let attachments: [ChatImageAttachment]

    var body: some View {
        if !attachments.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    thumbnail(for: attachment)
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 82, maximum: 120), spacing: 6)]
    }

    @ViewBuilder
    private func thumbnail(for attachment: ChatImageAttachment) -> some View {
        Group {
            #if os(macOS)
            if let data = Data(base64Encoded: attachment.thumbnailBase64), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
            #else
            if let data = Data(base64Encoded: attachment.thumbnailBase64), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
            #endif
        }
        .frame(width: 86, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .accessibilityLabel("Attached image \(attachment.displayName)")
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.surfaceHover)
            .overlay(Image(systemName: "photo").foregroundStyle(Theme.secondary))
    }
}
