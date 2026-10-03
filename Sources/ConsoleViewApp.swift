import SwiftUI
import AppKit

@main
struct ConsoleViewApp: App {
    @NSApplicationDelegateAdaptor(ConsoleViewDelegate.self) private var appDelegate
    @StateObject private var preferences: AppPreferences
    @StateObject private var controller: CaptureController

    init() {
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _controller = StateObject(wrappedValue: CaptureController(preferences: preferences))
    }

    var body: some Scene {
        Window("Console View", id: "console-view") {
            ConsoleRootView(controller: controller, preferences: preferences, appDelegate: appDelegate)
                .preferredColorScheme(preferences.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Console View") { appDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button(appDelegate.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") { appDelegate.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandMenu("Capture") {
                Menu("Change Source") {
                    if controller.devices.isEmpty {
                        Button("No capture cards connected") {}.disabled(true)
                    } else {
                        ForEach(controller.devices) { device in
                            Button { controller.chooseVideo(device.id) } label: {
                                if device.id == preferences.videoID || (preferences.videoID.isEmpty && controller.devices.count == 1) {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    }
                }
                Button("Return Home") { appDelegate.returnHome?() }
                    .disabled(!appDelegate.showingViewer)
                Divider()
                Toggle("Mute Audio", isOn: $preferences.muted)
                    .keyboardShortcut("m", modifiers: [.command])
            }
        }

        Settings {
            ConsoleSettingsView(controller: controller, preferences: preferences)
                .preferredColorScheme(preferences.colorScheme)
        }

    }
}

final class ConsoleViewDelegate: NSObject, ObservableObject, NSApplicationDelegate {
    weak var mainWindow: NSWindow?
    weak var controller: CaptureController?
    var reopenWindow: (() -> Void)?
    var returnHome: (() -> Void)?
    @Published private(set) var showingViewer = false
    @Published private(set) var isFullScreen = false
    private var keyboardMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var fullScreenDelegate: FullScreenWindowDelegate?
    private var aboutWindow: NSWindow?

    func attach(window: NSWindow, controller: CaptureController) {
        if mainWindow === window, window.delegate === fullScreenDelegate { return }
        restoreWindowDelegate()
        mainWindow = window
        self.controller = controller
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.controller?.stop()
            self?.isFullScreen = false
        }
        window.title = "Console View"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        let delegate = FullScreenWindowDelegate(owner: self, previous: window.delegate)
        fullScreenDelegate = delegate
        window.delegate = delegate
        updateFullScreenState(window)
        applyAppearance(controller.preferences.appearance)
        if keyboardMonitor == nil {
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.mainWindow,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(event.window?.firstResponder is NSTextView) else { return event }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "f": self.toggleFullScreen(); return nil
                case "m": self.controller?.preferences.muted.toggle(); return nil
                case "\u{1b}" where self.mainWindow?.styleMask.contains(.fullScreen) == true:
                    self.toggleFullScreen(); return nil
                default: return event
                }
            }
        }
    }

    func toggleFullScreen() {
        mainWindow?.toggleFullScreen(nil)
    }

    func setViewerVisible(_ visible: Bool) {
        showingViewer = visible
        if let controller { applyAppearance(controller.preferences.appearance) }
    }

    fileprivate func enteringFullScreen(_ window: NSWindow) {
        guard window === mainWindow else { return }
        isFullScreen = true
    }

    fileprivate func updateFullScreenState(_ window: NSWindow) {
        guard window === mainWindow else { return }
        isFullScreen = window.styleMask.contains(.fullScreen)
    }

    private func restoreWindowDelegate() {
        if let window = mainWindow, let fullScreenDelegate, window.delegate === fullScreenDelegate {
            window.delegate = fullScreenDelegate.previous
        }
        fullScreenDelegate = nil
    }

    func applyAppearance(_ value: String) {
        NSApp.appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
        mainWindow?.appearance = showingViewer ? NSAppearance(named: .darkAqua) : NSApp.appearance
    }

    func showAbout() {
        if let aboutWindow {
            aboutWindow.deminiaturize(nil)
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }
        let content = NSHostingView(rootView: ConsoleAboutView())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "About Console View"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = mainWindow, window.isVisible {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow?()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        restoreWindowDelegate()
    }
}

// Preserve SwiftUI's window delegate while handling AppKit fullscreen failures.
private final class FullScreenWindowDelegate: NSObject, NSWindowDelegate {
    weak var owner: ConsoleViewDelegate?
    weak var previous: NSWindowDelegate?

    init(owner: ConsoleViewDelegate, previous: NSWindowDelegate?) {
        self.owner = owner
        self.previous = previous
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if previous?.responds(to: selector) == true { return previous }
        return super.forwardingTarget(for: selector)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow { owner?.enteringFullScreen(window) }
        previous?.windowWillEnterFullScreen?(notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        previous?.windowDidEnterFullScreen?(notification)
        if let window = notification.object as? NSWindow { owner?.updateFullScreenState(window) }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        previous?.windowWillExitFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        previous?.windowDidExitFullScreen?(notification)
        if let window = notification.object as? NSWindow { owner?.updateFullScreenState(window) }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        previous?.windowDidFailToEnterFullScreen?(window)
        owner?.updateFullScreenState(window)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        previous?.windowDidFailToExitFullScreen?(window)
        owner?.updateFullScreenState(window)
    }
}


struct ConsoleAboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            OriginalAppIcon()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Console View")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .padding(.top, 18)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            Text("Created by El Qorchi Ismail")
                .font(.system(size: 13))
                .padding(.top, 24)
            HStack(spacing: 14) {
                Link(destination: URL(string: "https://github.com/smailkorchi")!) {
                    GitHubMark().fill(.primary).frame(width: 22, height: 22)
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                }
                .help("GitHub · smailkorchi")
                .accessibilityLabel("GitHub profile, smailkorchi")
                Link(destination: URL(string: "https://www.instagram.com/ismail.elqorchi/")!) {
                    InstagramMark().fill(.primary).frame(width: 22, height: 22)
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                }
                .help("Instagram · ismail.elqorchi")
                .accessibilityLabel("Instagram profile, ismail.elqorchi")
            }
            .buttonStyle(.borderless)
            .padding(.top, 15)
        }
        .padding(36)
        .frame(width: 350)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// GitHub's official Invertocat vector: https://brand.github.com/foundations/logo
private struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 41.439500, y: 69.384800))
        path.addCurve(to: CGPoint(x: 19.906200, y: 46.990200), control1: CGPoint(x: 28.806600, y: 67.853500), control2: CGPoint(x: 19.906200, y: 58.761700))
        path.addCurve(to: CGPoint(x: 24.500000, y: 33.591800), control1: CGPoint(x: 19.906200, y: 42.205100), control2: CGPoint(x: 21.628900, y: 37.037100))
        path.addCurve(to: CGPoint(x: 24.882800, y: 20.959000), control1: CGPoint(x: 23.255900, y: 30.433600), control2: CGPoint(x: 23.447300, y: 23.734400))
        path.addCurve(to: CGPoint(x: 36.941400, y: 25.265600), control1: CGPoint(x: 28.710900, y: 20.480500), control2: CGPoint(x: 33.878900, y: 22.490200))
        path.addCurve(to: CGPoint(x: 49.095700, y: 23.543000), control1: CGPoint(x: 40.578100, y: 24.117200), control2: CGPoint(x: 44.406200, y: 23.543000))
        path.addCurve(to: CGPoint(x: 61.058600, y: 25.169900), control1: CGPoint(x: 53.785200, y: 23.543000), control2: CGPoint(x: 57.613300, y: 24.117200))
        path.addCurve(to: CGPoint(x: 73.117200, y: 20.959000), control1: CGPoint(x: 64.025400, y: 22.490200), control2: CGPoint(x: 69.289100, y: 20.480500))
        path.addCurve(to: CGPoint(x: 73.404300, y: 33.496100), control1: CGPoint(x: 74.457000, y: 23.543000), control2: CGPoint(x: 74.648400, y: 30.242200))
        path.addCurve(to: CGPoint(x: 78.093700, y: 46.990200), control1: CGPoint(x: 76.466800, y: 37.132800), control2: CGPoint(x: 78.093700, y: 42.013700))
        path.addCurve(to: CGPoint(x: 56.369100, y: 69.289100), control1: CGPoint(x: 78.093700, y: 58.761700), control2: CGPoint(x: 69.193400, y: 67.662100))
        path.addCurve(to: CGPoint(x: 61.824200, y: 81.252000), control1: CGPoint(x: 59.623000, y: 71.394500), control2: CGPoint(x: 61.824200, y: 75.988300))
        path.addLine(to: CGPoint(x: 61.824200, y: 91.205100))
        path.addCurve(to: CGPoint(x: 67.087900, y: 94.554700), control1: CGPoint(x: 61.824200, y: 94.076200), control2: CGPoint(x: 64.216800, y: 95.703100))
        path.addCurve(to: CGPoint(x: 98.000000, y: 49.191400), control1: CGPoint(x: 84.410200, y: 87.951200), control2: CGPoint(x: 98.000000, y: 70.628900))
        path.addCurve(to: CGPoint(x: 48.904300, y: 0.000000), control1: CGPoint(x: 98.000000, y: 22.107400), control2: CGPoint(x: 75.988300, y: 0.000001))
        path.addCurve(to: CGPoint(x: -0.000000, y: 49.191400), control1: CGPoint(x: 21.820300, y: 0.000000), control2: CGPoint(x: -0.000000, y: 22.107400))
        path.addCurve(to: CGPoint(x: 31.677700, y: 94.650400), control1: CGPoint(x: -0.000001, y: 70.437500), control2: CGPoint(x: 13.494100, y: 88.046900))
        path.addCurve(to: CGPoint(x: 36.750000, y: 91.300800), control1: CGPoint(x: 34.261700, y: 95.607400), control2: CGPoint(x: 36.750000, y: 93.884800))
        path.addLine(to: CGPoint(x: 36.750000, y: 83.644500))
        path.addCurve(to: CGPoint(x: 32.156200, y: 84.601600), control1: CGPoint(x: 35.410200, y: 84.218800), control2: CGPoint(x: 33.687500, y: 84.601600))
        path.addCurve(to: CGPoint(x: 19.427700, y: 74.744100), control1: CGPoint(x: 25.839800, y: 84.601600), control2: CGPoint(x: 22.107400, y: 81.156300))
        path.addCurve(to: CGPoint(x: 15.025400, y: 70.341800), control1: CGPoint(x: 18.375000, y: 72.160200), control2: CGPoint(x: 17.226600, y: 70.628900))
        path.addCurve(to: CGPoint(x: 13.494100, y: 69.193400), control1: CGPoint(x: 13.877000, y: 70.246100), control2: CGPoint(x: 13.494100, y: 69.767600))
        path.addCurve(to: CGPoint(x: 17.322300, y: 67.183600), control1: CGPoint(x: 13.494100, y: 68.044900), control2: CGPoint(x: 15.408200, y: 67.183600))
        path.addCurve(to: CGPoint(x: 24.978500, y: 72.447300), control1: CGPoint(x: 20.097700, y: 67.183600), control2: CGPoint(x: 22.490200, y: 68.906300))
        path.addCurve(to: CGPoint(x: 31.294900, y: 76.466800), control1: CGPoint(x: 26.892600, y: 75.222700), control2: CGPoint(x: 28.902300, y: 76.466800))
        path.addCurve(to: CGPoint(x: 37.419900, y: 73.404300), control1: CGPoint(x: 33.687500, y: 76.466800), control2: CGPoint(x: 35.218700, y: 75.605500))
        path.addCurve(to: CGPoint(x: 41.439500, y: 69.384800), control1: CGPoint(x: 39.046900, y: 71.777300), control2: CGPoint(x: 40.291000, y: 70.341800))
        path.closeSubpath()
        let scale = min(rect.width / 98, rect.height / 96)
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.midX - 98 * scale / 2, y: rect.midY - 96 * scale / 2)))
    }
}

// Instagram glyph from Simple Icons (CC0), retaining its original path geometry.
// https://github.com/simple-icons/simple-icons/blob/develop/icons/instagram.svg
private struct InstagramMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7.030100, y: 0.084000))
        path.addCurve(to: CGPoint(x: 4.119100, y: 0.647400), control1: CGPoint(x: 5.753300, y: 0.144200), control2: CGPoint(x: 4.881400, y: 0.348000))
        path.addCurve(to: CGPoint(x: 1.996300, y: 2.035100), control1: CGPoint(x: 3.330300, y: 0.954900), control2: CGPoint(x: 2.661600, y: 1.367400))
        path.addCurve(to: CGPoint(x: 0.616100, y: 4.162100), control1: CGPoint(x: 1.331100, y: 2.702800), control2: CGPoint(x: 0.921300, y: 3.371900))
        path.addCurve(to: CGPoint(x: 0.064100, y: 7.076100), control1: CGPoint(x: 0.320700, y: 4.925900), control2: CGPoint(x: 0.120500, y: 5.798600))
        path.addCurve(to: CGPoint(x: 0.001500, y: 12.023100), control1: CGPoint(x: 0.007700, y: 8.353600), control2: CGPoint(x: -0.004800, y: 8.764300))
        path.addCurve(to: CGPoint(x: 0.084000, y: 16.970400), control1: CGPoint(x: 0.007700, y: 15.281700), control2: CGPoint(x: 0.022100, y: 15.690200))
        path.addCurve(to: CGPoint(x: 0.647500, y: 19.881100), control1: CGPoint(x: 0.145000, y: 18.246900), control2: CGPoint(x: 0.348000, y: 19.118600))
        path.addCurve(to: CGPoint(x: 2.035500, y: 22.003900), control1: CGPoint(x: 0.955500, y: 20.670000), control2: CGPoint(x: 1.367500, y: 21.338400))
        path.addCurve(to: CGPoint(x: 4.164000, y: 23.383900), control1: CGPoint(x: 2.703400, y: 22.669400), control2: CGPoint(x: 3.372000, y: 23.078200))
        path.addCurve(to: CGPoint(x: 7.077400, y: 23.935900), control1: CGPoint(x: 4.927200, y: 23.678900), control2: CGPoint(x: 5.800100, y: 23.880000))
        path.addCurve(to: CGPoint(x: 12.023600, y: 23.998600), control1: CGPoint(x: 8.354700, y: 23.991900), control2: CGPoint(x: 8.765800, y: 24.004900))
        path.addCurve(to: CGPoint(x: 16.971400, y: 23.917200), control1: CGPoint(x: 15.281400, y: 23.992400), control2: CGPoint(x: 15.691600, y: 23.977900))
        path.addCurve(to: CGPoint(x: 19.881200, y: 23.353900), control1: CGPoint(x: 18.251400, y: 23.856500), control2: CGPoint(x: 19.118400, y: 23.652000))
        path.addCurve(to: CGPoint(x: 22.004000, y: 21.965800), control1: CGPoint(x: 20.670100, y: 23.045300), control2: CGPoint(x: 21.339000, y: 22.633900))
        path.addCurve(to: CGPoint(x: 23.383500, y: 19.837400), control1: CGPoint(x: 22.669000, y: 21.297600), control2: CGPoint(x: 23.078500, y: 20.628000))
        path.addCurve(to: CGPoint(x: 23.935500, y: 16.925000), control1: CGPoint(x: 23.679200, y: 19.074200), control2: CGPoint(x: 23.880100, y: 18.201400))
        path.addCurve(to: CGPoint(x: 23.998500, y: 11.977000), control1: CGPoint(x: 23.991500, y: 15.644100), control2: CGPoint(x: 24.004700, y: 15.235200))
        path.addCurve(to: CGPoint(x: 23.916800, y: 7.030500), control1: CGPoint(x: 23.992200, y: 8.718700), control2: CGPoint(x: 23.977500, y: 8.310200))
        path.addCurve(to: CGPoint(x: 23.353500, y: 4.118800), control1: CGPoint(x: 23.856100, y: 5.750800), control2: CGPoint(x: 23.652800, y: 4.881800))
        path.addCurve(to: CGPoint(x: 21.965900, y: 1.996000), control1: CGPoint(x: 23.045100, y: 3.329900), control2: CGPoint(x: 22.633500, y: 2.662000))
        path.addCurve(to: CGPoint(x: 19.837800, y: 0.616500), control1: CGPoint(x: 21.298200, y: 1.330000), control2: CGPoint(x: 20.628000, y: 0.920800))
        path.addCurve(to: CGPoint(x: 16.924400, y: 0.064500), control1: CGPoint(x: 19.074000, y: 0.321000), control2: CGPoint(x: 18.201700, y: 0.119700))
        path.addCurve(to: CGPoint(x: 11.977000, y: 0.001400), control1: CGPoint(x: 15.647100, y: 0.009300), control2: CGPoint(x: 15.236000, y: -0.005000))
        path.addCurve(to: CGPoint(x: 7.030100, y: 0.083900), control1: CGPoint(x: 8.718000, y: 0.007600), control2: CGPoint(x: 8.310000, y: 0.021500))
        path.move(to: CGPoint(x: 7.170300, y: 21.777100))
        path.addCurve(to: CGPoint(x: 4.941600, y: 21.369100), control1: CGPoint(x: 6.000300, y: 21.726200), control2: CGPoint(x: 5.365000, y: 21.531800))
        path.addCurve(to: CGPoint(x: 3.559700, y: 20.474100), control1: CGPoint(x: 4.381000, y: 21.153100), control2: CGPoint(x: 3.981600, y: 20.892000))
        path.addCurve(to: CGPoint(x: 2.659700, y: 19.096100), control1: CGPoint(x: 3.137700, y: 20.056300), control2: CGPoint(x: 2.878600, y: 19.655500))
        path.addCurve(to: CGPoint(x: 2.242600, y: 16.868100), control1: CGPoint(x: 2.495300, y: 18.672700), control2: CGPoint(x: 2.297300, y: 18.038100))
        path.addCurve(to: CGPoint(x: 2.163600, y: 12.020100), control1: CGPoint(x: 2.183100, y: 15.603600), control2: CGPoint(x: 2.170600, y: 15.223900))
        path.addCurve(to: CGPoint(x: 2.224300, y: 7.172100), control1: CGPoint(x: 2.156600, y: 8.816400), control2: CGPoint(x: 2.168900, y: 8.437100))
        path.addCurve(to: CGPoint(x: 2.632300, y: 4.943900), control1: CGPoint(x: 2.274300, y: 6.003100), control2: CGPoint(x: 2.469900, y: 5.367100))
        path.addCurve(to: CGPoint(x: 3.527300, y: 3.562300), control1: CGPoint(x: 2.848300, y: 4.382600), control2: CGPoint(x: 3.108500, y: 3.983900))
        path.addCurve(to: CGPoint(x: 4.905600, y: 2.662000), control1: CGPoint(x: 3.946100, y: 3.140600), control2: CGPoint(x: 4.345700, y: 2.880900))
        path.addCurve(to: CGPoint(x: 7.132600, y: 2.244900), control1: CGPoint(x: 5.328600, y: 2.496900), control2: CGPoint(x: 5.963100, y: 2.300600))
        path.addCurve(to: CGPoint(x: 11.980600, y: 2.165900), control1: CGPoint(x: 8.398100, y: 2.184900), control2: CGPoint(x: 8.777300, y: 2.172900))
        path.addCurve(to: CGPoint(x: 16.830100, y: 2.226700), control1: CGPoint(x: 15.183900, y: 2.158900), control2: CGPoint(x: 15.564100, y: 2.170900))
        path.addCurve(to: CGPoint(x: 19.058100, y: 2.634700), control1: CGPoint(x: 17.999100, y: 2.277500), control2: CGPoint(x: 18.635400, y: 2.471200))
        path.addCurve(to: CGPoint(x: 20.439700, y: 3.529700), control1: CGPoint(x: 19.618900, y: 2.850700), control2: CGPoint(x: 20.018100, y: 3.110100))
        path.addCurve(to: CGPoint(x: 21.340200, y: 4.908400), control1: CGPoint(x: 20.861400, y: 3.949100), control2: CGPoint(x: 21.121300, y: 4.347300))
        path.addCurve(to: CGPoint(x: 21.757100, y: 7.134700), control1: CGPoint(x: 21.505500, y: 5.330100), control2: CGPoint(x: 21.701900, y: 5.964400))
        path.addCurve(to: CGPoint(x: 21.836700, y: 11.982700), control1: CGPoint(x: 21.817300, y: 8.400200), control2: CGPoint(x: 21.831000, y: 8.779700))
        path.addCurve(to: CGPoint(x: 21.775700, y: 16.830700), control1: CGPoint(x: 21.842500, y: 15.185700), control2: CGPoint(x: 21.831200, y: 15.566100))
        path.addCurve(to: CGPoint(x: 21.367700, y: 19.060100), control1: CGPoint(x: 21.724700, y: 18.000700), control2: CGPoint(x: 21.530700, y: 18.636200))
        path.addCurve(to: CGPoint(x: 20.472300, y: 20.441500), control1: CGPoint(x: 21.151700, y: 19.620500), control2: CGPoint(x: 20.891400, y: 20.020100))
        path.addCurve(to: CGPoint(x: 19.094000, y: 21.341500), control1: CGPoint(x: 20.053300, y: 20.863000), control2: CGPoint(x: 19.654200, y: 21.122600))
        path.addCurve(to: CGPoint(x: 16.867800, y: 21.758900), control1: CGPoint(x: 18.671600, y: 21.506400), control2: CGPoint(x: 18.036300, y: 21.703200))
        path.addCurve(to: CGPoint(x: 12.018500, y: 21.837900), control1: CGPoint(x: 15.602200, y: 21.818400), control2: CGPoint(x: 15.223000, y: 21.830900))
        path.addCurve(to: CGPoint(x: 7.170500, y: 21.777100), control1: CGPoint(x: 8.814000, y: 21.844900), control2: CGPoint(x: 8.436000, y: 21.831900))
        path.move(to: CGPoint(x: 16.953000, y: 5.586400))
        path.addCurve(to: CGPoint(x: 17.844292, y: 6.915358), control1: CGPoint(x: 16.953972, y: 6.168879), control2: CGPoint(x: 17.305757, y: 6.693407))
        path.addCurve(to: CGPoint(x: 19.413140, y: 6.600319), control1: CGPoint(x: 18.382828, y: 7.137309), control2: CGPoint(x: 19.002037, y: 7.012966))
        path.addCurve(to: CGPoint(x: 19.722292, y: 5.030301), control1: CGPoint(x: 19.824242, y: 6.187672), control2: CGPoint(x: 19.946261, y: 5.568000))
        path.addCurve(to: CGPoint(x: 18.390000, y: 4.144000), control1: CGPoint(x: 19.498322, y: 4.492602), control2: CGPoint(x: 18.972479, y: 4.142787))
        path.addCurve(to: CGPoint(x: 16.953000, y: 5.586400), control1: CGPoint(x: 17.594944, y: 4.145655), control2: CGPoint(x: 16.951673, y: 4.791343))
        path.move(to: CGPoint(x: 5.838500, y: 12.012000))
        path.addCurve(to: CGPoint(x: 12.011500, y: 18.161300), control1: CGPoint(x: 5.845200, y: 15.415200), control2: CGPoint(x: 8.609100, y: 18.167700))
        path.addCurve(to: CGPoint(x: 18.162100, y: 11.988000), control1: CGPoint(x: 15.414100, y: 18.154800), control2: CGPoint(x: 18.168500, y: 15.391200))
        path.addCurve(to: CGPoint(x: 11.988100, y: 5.838200), control1: CGPoint(x: 18.155600, y: 8.584800), control2: CGPoint(x: 15.391100, y: 5.831500))
        path.addCurve(to: CGPoint(x: 5.838500, y: 12.012000), control1: CGPoint(x: 8.585100, y: 5.844900), control2: CGPoint(x: 5.832100, y: 8.609200))
        path.move(to: CGPoint(x: 8.000000, y: 12.007700))
        path.addCurve(to: CGPoint(x: 11.992062, y: 7.999816), control1: CGPoint(x: 7.995641, y: 9.798580), control2: CGPoint(x: 9.782942, y: 8.004196))
        path.addCurve(to: CGPoint(x: 15.999984, y: 11.991839), control1: CGPoint(x: 14.201181, y: 7.995436), control2: CGPoint(x: 15.995583, y: 9.782719))
        path.addCurve(to: CGPoint(x: 12.008000, y: 15.999800), control1: CGPoint(x: 16.004386, y: 14.200958), control2: CGPoint(x: 14.217119, y: 15.995377))
        path.addCurve(to: CGPoint(x: 9.177075, y: 14.833968), control1: CGPoint(x: 10.947084, y: 16.002030), control2: CGPoint(x: 9.928747, y: 15.582659))
        path.addCurve(to: CGPoint(x: 8.000000, y: 12.007700), control1: CGPoint(x: 8.425403, y: 14.085278), control2: CGPoint(x: 8.001987, y: 13.068617))
        let scale = min(rect.width / 24, rect.height / 24)
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.midX - 24 * scale / 2, y: rect.midY - 24 * scale / 2)))
    }
}
