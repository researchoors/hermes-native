import SwiftUI

/// Shared app helpers used by the platform-specific @main entry points.
///
/// Keep @StateObject ownership in the concrete App structs. Do not wrap one
/// App inside another App (e.g. `HermesNativeApp().body`), because SwiftUI will
/// access those StateObjects before the owner is installed and create transient
/// instances.
func requestHermesNativeNotificationAuthorization() {
    Task {
        _ = await NotificationService.shared.requestAuthorization()
    }
}

#if os(macOS)
import AppKit

func configureHermesNativeMacApplication() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
}

/// Applies the macOS window chrome configuration SwiftUI does not expose.
/// This intentionally keeps the standard red/yellow/green window controls
/// visible while allowing the app content to extend behind a transparent titlebar.
struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Keep a normal titled/closable/resizable window. The hidden-titlebar
        // SwiftUI style + full-size content view removes the title text/chrome
        // band, but the standard traffic-light controls still require the
        // standard titled window buttons to remain present and ordered front.
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.styleMask.remove(.borderless)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.background)

        // Do not hide or remove the standard close/minimize/zoom buttons.
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(buttonType) {
                button.isHidden = false
                button.alphaValue = 1
                button.isEnabled = true
                button.wantsLayer = true
                button.layer?.zPosition = 10_000
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
                button.superview?.addSubview(button, positioned: .above, relativeTo: nil)
            }
        }
    }
}
#endif
