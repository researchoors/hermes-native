import SwiftUI

/// A macOS-safe alternative to ProgressView that avoids the
/// "Unable to render flattened version of PlatformViewRepresentableAdaptor<AppKitProgressView>"
/// diagnostic by using a SwiftUI-native spinner instead of the AppKit NSProgressIndicator.
struct HermesProgressView: View {
    var label: String? = nil

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Theme.accent, lineWidth: 2)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            if let label = label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { isAnimating = true }
    }
}
