import AppKit
import SwiftUI

/// The menu bar item: a small glass panel under the icon.
///
/// A panel rather than an NSMenu, because a menu is only rows of text. The
/// moment it holds a switch or a row of icon buttons, those controls are
/// guests in the menu's event tracking: buttons never see their mouse-up, a
/// menu cannot open a second menu, and every control draws in its inactive
/// grey because a menu's window is never key. In a real window all of that
/// is ordinary SwiftUI.
///
/// Rounded, and glass, by construction: NSGlassEffectView on macOS 26, the
/// popover material with the same corner radius before it.
@MainActor
final class StatusPanelController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: StatusPanel
    private let hosting: NSHostingView<AnyView>
    private var outsideClickMonitor: Any?

    private static let cornerRadius: CGFloat = 18

    init(server: ServerManager,
         permissions: PermissionsMonitor,
         updater: UpdaterController,
         onShowSetup: @escaping () -> Void) {
        panel = StatusPanel()
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()

        let content = StatusPanelView(
            server: server,
            permissions: permissions,
            updater: updater,
            onShowSetup: { [weak self] in
                self?.close()
                onShowSetup()
            },
            onQuit: {
                server.stop()
                NSApp.terminate(nil)
            },
            onUninstall: { [weak self] in
                self?.close()
                Uninstaller.confirmAndRun(server: server)
            },
            onCheckForUpdates: { [weak self] in
                self?.close()
                updater.checkForUpdates()
            },
            onSizeChange: { [weak self] size in self?.resize(to: size) }
        )
        hosting.rootView = AnyView(content)
        panel.contentView = Self.glassContainer(around: hosting)

        statusItem.button?.image = MenuBarIcon.image
        statusItem.button?.setAccessibilityLabel("Air Mouse")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        panel.onEscape = { [weak self] in self?.close() }
    }

    private static func glassContainer(around content: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        #endif
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        return material
    }

    // MARK: - Showing

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        resize(to: hosting.fittingSize)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        // Any click outside — another app, the desktop, the menu bar — closes
        // it, the way a menu would. Clicks on the status item itself arrive
        // through `toggle` instead, which is why they are not handled here.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Keeps the panel hanging from the icon as its content grows or shrinks.
    private func resize(to size: NSSize) {
        guard size.width > 0, size.height > 0,
              let button = statusItem.button, let buttonWindow = button.window
        else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = anchor.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

/// Borderless, transparent, and allowed to become key — so its controls draw
/// active — without activating the app and taking focus from whatever the
/// phone is typing into.
private final class StatusPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Content

struct StatusPanelView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var permissions: PermissionsMonitor
    @ObservedObject var updater: UpdaterController
    var onShowSetup: () -> Void
    var onQuit: () -> Void
    var onUninstall: () -> Void
    var onCheckForUpdates: () -> Void
    var onSizeChange: (NSSize) -> Void

    @State private var showQR = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if !permissions.isTrusted {
                divider
                Row(action: onShowSetup) {
                    Label("Allow Control", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }

            if let pin = server.pin {
                divider
                Row(action: { copy(pin) }) {
                    Text("Pairing code")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(copied ? "Copied" : pin.map(String.init).joined(separator: " "))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .help("Click to copy")
            }

            divider
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onSizeChange(proxy.size) }
                .onChange(of: proxy.size) { onSizeChange($0) }
        })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Air Mouse")
                    .font(.headline)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Server", isOn: Binding(
                get: { server.isRunning },
                set: { $0 ? server.start() : server.stop() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            if let url = server.url {
                FooterButton(symbol: "qrcode", label: "Pair a Browser") { showQR.toggle() }
                    .popover(isPresented: $showQR, arrowEdge: .bottom) {
                        BrowserPairing(url: url)
                            .padding(14)
                            .frame(width: 180)
                    }
            }
            Menu {
                Button(action: onCheckForUpdates) {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
                }
                .disabled(!updater.canCheckForUpdates)
                Button(action: onShowSetup) {
                    Label("Setup…", systemImage: "wand.and.stars")
                }
                Divider()
                Button(role: .destructive, action: onUninstall) {
                    Label("Uninstall…", systemImage: "trash")
                }
                Button(action: onQuit) {
                    Label("Quit Air Mouse", systemImage: "xmark")
                }
                .keyboardShortcut("q")
                Divider()
                Text("Version \(appVersion)")
            } label: {
                FooterIcon(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private var divider: some View {
        Divider().padding(.horizontal, 14)
    }

    private func copy(_ pin: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private var statusText: String {
        switch server.statusMessage {
        case "Running": return permissions.isTrusted ? "Ready" : "Needs permission"
        case "Stopped": return "Off"
        case "Starting…": return "Starting"
        default: return "Couldn't start"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// A full-width row with the menu-style hover highlight.
private struct Row<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }
}

private struct FooterIcon: View {
    let symbol: String
    var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .background(Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Circle())
    }
}

private struct FooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            FooterIcon(symbol: symbol, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
