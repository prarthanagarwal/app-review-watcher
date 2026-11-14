import AppKit
import SwiftUI

@main
struct Launcher {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: args[i + 1], dark: args.contains("--dark"))
            return
        }
        WatcherApp.main()
    }
}

struct WatcherApp: App {
    @StateObject private var store = Store()

    init() {
        // Only one copy should live in the menu bar.
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
                .onAppear { store.reload() }
                .onDisappear { store.markSeen() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in store.reload() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in store.markSeen() }
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The item in the menu bar: a quiet icon normally, colour and a word when something needs attention.
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        if !store.openEvents.isEmpty {
            HStack(spacing: 4) {
                Image(nsImage: Self.symbol("calendar.badge.checkmark", color: .systemGreen))
                Text("Open")
            }
        } else if store.unseenCount > 0 {
            HStack(spacing: 3) {
                Image(nsImage: Self.symbol("bell.badge.fill", color: .systemRed))
                Text("\(store.unseenCount)")
            }
        } else if store.health != .ok {
            Image(nsImage: Self.symbol("exclamationmark.triangle.fill", color: .systemOrange))
        } else {
            Image(systemName: "calendar.badge.clock")
        }
    }

    static func symbol(_ name: String, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// Renders the panel to a PNG without showing it, so the design can be checked from the command line:
///   WATCH_DATA_DIR=some/folder AppReviewWatcher --snapshot out.png [--dark]
enum Snapshot {
    @MainActor static func render(to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.appearance = appearance

        let panel = PanelView(store: Store(live: false))
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(18)
            .background(Color(nsColor: dark ? .black : .lightGray))

        let host = NSHostingView(rootView: panel)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale, pixelsHigh: Int(host.bounds.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("snapshot failed: \(error)"); exit(1) }
        print("wrote \(path)")
    }
}
