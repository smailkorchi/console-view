import SwiftUI
import AppKit
import AVFoundation

// Disambiguate the property wrapper from the State macro in newer SDKs.
private typealias NativeState<Value> = SwiftUI.State<Value>

enum PreviewState {
    case none, home, reconnecting, permission, settings

    static var current: PreviewState {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-home") { return .home }
        if arguments.contains("--preview-reconnecting") { return .reconnecting }
        if arguments.contains("--preview-permission") { return .permission }
        if arguments.contains("--preview-settings") { return .settings }
        return .none
    }
}

struct ConsoleRootView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var appDelegate: ConsoleViewDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @NativeState private var hasViewed = PreviewState.current == .reconnecting
    @NativeState private var showingSources = false
    @NativeState private var showingHelp = false

    private var phase: CapturePhase {
        switch PreviewState.current {
        case .home, .settings: return .waiting
        case .reconnecting: return .reconnecting
        case .permission: return .denied
        case .none: return controller.phase
        }
    }

    private var message: String {
        switch PreviewState.current {
        case .home, .settings: return "Waiting for a capture card"
        case .reconnecting: return "Your capture card was disconnected. Reconnect it to continue."
        case .permission: return "Allow Camera access in System Settings to view your capture card."
        case .none: return controller.message
        }
    }

    var body: some View {
        ZStack {
            ConsoleSurface()
            if hasViewed || appDelegate.isFullScreen {
                viewer
                    .ignoresSafeArea(.container, edges: appDelegate.isFullScreen ? .all : [])
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.985)))
            } else {
                home
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 1.015)))
            }
            if PreviewState.current != .none && !appDelegate.isFullScreen {
                VStack {
                    Text("Interface preview · Capture is off")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .background(WindowAttachment(controller: controller, appDelegate: appDelegate))
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.3, dampingFraction: 1), value: hasViewed)
        .sheet(isPresented: $showingHelp) { ConnectionHelpView() }
        .onAppear {
            appDelegate.returnHome = { stop() }
            appDelegate.reopenWindow = {
                hasViewed = false
                if PreviewState.current == .none { controller.launch() }
                openWindow(id: "console-view")
            }
            appDelegate.setViewerVisible(hasViewed)
            appDelegate.applyAppearance(preferences.appearance)
        }
        .task {
            if PreviewState.current == .none { controller.launch() }
            if PreviewState.current == .settings { openSettings() }
        }
        .onChange(of: hasViewed) { _, visible in appDelegate.setViewerVisible(visible) }
        .onChange(of: appDelegate.isFullScreen) { _, fullScreen in
            if fullScreen {
                showingSources = false
                showingHelp = false
            }
        }
        .onChange(of: controller.devices.count) { _, count in
            if count < 2 { showingSources = false }
        }
        .onChange(of: preferences.appearance) { _, value in appDelegate.applyAppearance(value) }
        .onChange(of: controller.phase) { _, newPhase in
            guard PreviewState.current == .none else { return }
            if newPhase == .live { hasViewed = true }
            if newPhase == .stopped { hasViewed = false }
        }
    }

    private var home: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Spacer(minLength: 62)
                OriginalAppIcon()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("Console View")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.65)
                    .padding(.top, 20)
                Text("Your console. Your Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
                sourceWell
                    .padding(.top, 24)
                if phase == .denied {
                    Button("Open Privacy Settings") {
                        if PreviewState.current == .none { controller.openPrivacySettings() }
                    }
                    .buttonStyle(ConsolePrimaryButtonStyle())
                    .frame(width: 190, height: 36)
                    .padding(.top, 22)
                }
                Button("Connection Help") { showingHelp = true }
                    .font(.system(size: 12))
                    .buttonStyle(.link)
                    .padding(.top, 14)
                statusLine
                    .padding(.top, 24)
                Spacer(minLength: 62)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sourceWell: some View {
        Button {
            guard PreviewState.current == .none else { return }
            if controller.devices.count == 1, let device = controller.devices.first {
                controller.chooseVideo(device.id)
            } else if controller.devices.count > 1 {
                showingSources.toggle()
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 25)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(sourceSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if PreviewState.current == .none && !controller.devices.isEmpty {
                    Image(systemName: controller.devices.count == 1 ? "play.fill" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(controller.devices.count == 1 ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 360, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ConsoleSourceButtonStyle())
        .disabled(PreviewState.current != .none || controller.devices.isEmpty)
        .accessibilityLabel("Capture source, \(sourceTitle)")
        .help(controller.devices.count == 1 ? "Click to view this capture card" : "Choose a connected capture card")
        .popover(isPresented: $showingSources, arrowEdge: .trailing) {
            sourceChooser
        }
    }

    private var sourceTitle: String {
        if PreviewState.current != .none { return "No capture device" }
        if controller.devices.count == 1 { return controller.devices[0].name }
        if !preferences.videoID.isEmpty {
            if let selected = controller.devices.first(where: { $0.id == preferences.videoID }) { return selected.name }
            return "Selected card — disconnected"
        }
        return controller.devices.isEmpty ? "No capture device" : "Choose a capture device"
    }

    private var sourceSubtitle: String {
        if PreviewState.current != .none { return "Connect an HDMI capture card" }
        if controller.devices.count == 1 { return "Click to view" }
        if controller.devices.count > 1 { return "Click to choose a capture card" }
        if !preferences.videoID.isEmpty && !controller.devices.contains(where: { $0.id == preferences.videoID }) {
            return "Reconnect your selected capture card"
        }
        return "Connect an HDMI capture card"
    }

    private var sourceChooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture Source").font(.headline)
            if controller.devices.isEmpty || PreviewState.current != .none {
                Text("Connect the card’s USB cable to your Mac, then connect your console to the card’s HDMI input.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.devices) { device in
                    Button {
                        controller.chooseVideo(device.id)
                        showingSources = false
                    } label: {
                        HStack {
                            Text(device.name).lineLimit(1)
                            Spacer()
                            if device.id == preferences.videoID || (preferences.videoID.isEmpty && controller.devices.count == 1) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                            Label("View", systemImage: "play.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("View \(device.name)")
                }
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            if phase == .connecting || phase == .requestingPermission {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: phase == .denied || phase == .failed ? "exclamationmark.circle" : "circle.fill")
                    .font(.system(size: phase == .denied || phase == .failed ? 11 : 6))
                    .accessibilityHidden(true)
            }
            Text(message.isEmpty ? "Ready when you are" : message)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 390)
        .accessibilityElement(children: .combine)
    }

    private var viewer: some View {
        ZStack {
            Color.black
            if let session = controller.session, PreviewState.current == .none {
                CapturePreview(session: session, gravity: preferences.gravity)
            }
            if !appDelegate.isFullScreen {
                if phase != .live {
                    recovery
                }
                VStack {
                    Spacer()
                    viewerControls
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
                if preferences.showStats && phase == .live && PreviewState.current == .none {
                    VStack {
                        HStack {
                            Text("\(controller.resolution) · \(Int(controller.fps.rounded())) fps")
                                .font(.system(size: 11).monospacedDigit())
                                .padding(10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.top, 28)
                    .padding(.leading, 18)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Console viewer")
    }

    private var recovery: some View {
        VStack(spacing: 15) {
            Image(systemName: recoveryIcon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(recoveryTitle).font(.system(size: 22, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            if phase == .connecting || phase == .reconnecting || phase == .requestingPermission || phase == .failed || phase == .waiting {
                ProgressView().controlSize(.small)
            }
            if phase == .denied {
                Button("Open Privacy Settings") {
                    if PreviewState.current == .none { controller.openPrivacySettings() }
                }
                .padding(.top, 6)
            }
        }
        .padding(30)
    }

    private var recoveryTitle: String {
        switch phase {
        case .reconnecting: return "Reconnecting"
        case .denied: return "Camera Access Needed"
        case .failed: return "Unable to Start Capture"
        case .requestingPermission: return "Allow Capture Access"
        case .choosingSource: return "Choose Your Capture Card"
        default: return "Waiting for Your Capture Card"
        }
    }

    private var recoveryIcon: String {
        phase == .denied ? "camera" : phase == .failed ? "exclamationmark.circle" : "cable.connector"
    }

    private var viewerControls: some View {
        HStack(spacing: 16) {
            Button { preferences.muted.toggle() } label: {
                Image(systemName: preferences.muted || preferences.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help("Mute audio (M)")
            .accessibilityLabel(preferences.muted ? "Unmute audio" : "Mute audio")
            Slider(value: $preferences.volume, in: 0...1)
                .frame(width: 90)
                .controlSize(.small)
                .accessibilityLabel("Volume")
            Menu {
                Picker("Picture Size", selection: $preferences.pictureMode) {
                    Text("Fit — show the full picture").tag("fit")
                    Text("Fill — crop to fill the window").tag("fill")
                    Text("Stretch — change proportions").tag("stretch")
                }
            } label: { Image(systemName: "rectangle.arrowtriangle.2.outward") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 25)
            .help("Picture size")
            .accessibilityLabel("Picture size")
            Button { appDelegate.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Full screen (F)")
                .accessibilityLabel("Toggle full screen")
        }
        .font(.system(size: 13, weight: .medium))
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }

    private func stop() {
        if appDelegate.mainWindow?.styleMask.contains(.fullScreen) == true {
            appDelegate.toggleFullScreen()
        }
        controller.stop()
        hasViewed = false
    }
}

struct ConsoleSettingsView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Capture") {
                Picker("Video source", selection: Binding(get: { preferences.videoID }, set: { id in
                    if PreviewState.current == .none { controller.chooseVideo(id) } else { preferences.videoID = id }
                })) {
                    Text("Automatic").tag("")
                    if !preferences.videoID.isEmpty && !controller.devices.contains(where: { $0.id == preferences.videoID }) {
                        Text("Selected card — disconnected").tag(preferences.videoID)
                    }
                    ForEach(controller.devices) { Text($0.name).tag($0.id) }
                }
                Picker("Audio source", selection: $preferences.audioID) {
                    Text("Automatic").tag("auto")
                    Text("Off").tag("off")
                    if preferences.audioID != "auto", preferences.audioID != "off", !controller.audioDevices.contains(where: { $0.id == preferences.audioID }) {
                        Text("Selected audio — disconnected").tag(preferences.audioID)
                    }
                    ForEach(controller.audioDevices) { Text($0.name).tag($0.id) }
                }
                Text(controller.audioStatus.isEmpty ? "Automatic audio uses the capture card’s audio device when available." : controller.audioStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Capture quality", selection: $preferences.quality) {
                    Text("Automatic — best resolution").tag("auto")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                }
                Text("Automatic chooses the highest supported resolution, then the fastest frame rate at that resolution. The delivered frame rate depends on the capture card and console signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Picture") {
                Picker("Picture size", selection: $preferences.pictureMode) {
                    Text("Fit — full picture").tag("fit")
                    Text("Fill — cropped edges").tag("fill")
                    Text("Stretch — changed proportions").tag("stretch")
                }
                Toggle("Show resolution and frame rate", isOn: $preferences.showStats)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 520, height: 470)
        .onChange(of: preferences.audioID) { _, _ in updateCaptureSettings() }
        .onChange(of: preferences.quality) { _, _ in updateCaptureSettings() }
    }

    private func updateCaptureSettings() {
        if PreviewState.current == .none { controller.settingsChanged() }
    }
}

private struct ConnectionHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Connect Your Console").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close connection help")
            }
            helpRow("cable.connector", title: "Connect the capture card", detail: "Plug the card’s USB cable into your Mac. Connect your console’s HDMI cable to the card’s HDMI input.")
            helpRow("power", title: "Turn on your console", detail: "Console View finds a single capture card automatically. If several are connected, choose one from Capture Source.")
            helpRow("camera", title: "Allow capture access", detail: "Allow Camera access when macOS asks. Microphone permission is needed only for the capture card’s audio.")
            Text("A card can be connected without receiving a picture. If the console uses HDCP, protected content cannot be captured. Check your console and capture card instructions.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Full screen: F     Mute: M")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 480)
    }

    private func helpRow(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .frame(width: 25)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ConsoleSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        (colorScheme == .dark ? Color(red: 0.115, green: 0.123, blue: 0.133) : Color(red: 0.972, green: 0.969, blue: 0.963))
            .ignoresSafeArea()
    }
}

struct OriginalAppIcon: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        }
    }
}

private struct ConsolePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @NativeState private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.blue.opacity(configuration.isPressed ? 0.76 : hovered ? 0.92 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}

private struct ConsoleSourceButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @NativeState private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : scheme == .dark ? 0.12 : 0.08), lineWidth: 1))
            .brightness(configuration.isPressed ? (scheme == .dark ? 0.035 : -0.035) : hovered ? (scheme == .dark ? 0.015 : -0.015) : 0)
            .onHover { hovered = $0 }
    }
}

private struct WindowAttachment: NSViewRepresentable {
    let controller: CaptureController
    let appDelegate: ConsoleViewDelegate
    func makeNSView(context: Context) -> NSView { AttachmentView(controller: controller, appDelegate: appDelegate) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AttachmentView: NSView {
        let controller: CaptureController
        weak var appDelegate: ConsoleViewDelegate?
        init(controller: CaptureController, appDelegate: ConsoleViewDelegate) {
            self.controller = controller
            self.appDelegate = appDelegate
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { appDelegate?.attach(window: window, controller: controller) }
        }
    }
}

private struct CapturePreview: NSViewRepresentable {
    let session: AVCaptureSession
    let gravity: AVLayerVideoGravity
    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        return view
    }
    func updateNSView(_ view: PreviewHostView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.previewLayer.videoGravity = gravity
    }
    static func dismantleNSView(_ view: PreviewHostView, coordinator: ()) { view.previewLayer.session = nil }

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
