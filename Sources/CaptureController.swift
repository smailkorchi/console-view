import AppKit
import AVFoundation
import Combine
import CoreAudio
import IOKit.pwr_mgt

// Stop invalidates callbacks immediately, even while startRunning is blocking
// the session queue. Session work itself stays on that one queue.
private final class CaptureLifetime {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var viewing = false
    var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    var wantsViewing: Bool {
        lock.lock(); defer { lock.unlock() }
        return viewing
    }
    @discardableResult func advance(viewing: Bool) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        self.viewing = viewing
        value &+= 1
        return value
    }
    func advanceIfViewing() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard viewing else { return nil }
        value &+= 1
        return value
    }
    func matches(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == token
    }
}

private struct CaptureConfiguration: Equatable {
    var videoID: String
    let audioID: String
    var quality: String
    let volume: Float
    let muted: Bool
    init(_ preferences: AppPreferences) {
        videoID = preferences.videoID
        audioID = preferences.audioID
        quality = preferences.quality
        volume = preferences.volume
        muted = preferences.muted
    }
    var gain: Float { muted ? 0 : max(0, min(volume, 1)) }
    func needsRebuild(from old: CaptureConfiguration) -> Bool {
        videoID != old.videoID || audioID != old.audioID || quality != old.quality
    }
}

private final class VideoMetrics: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let update: (Int32, Int32, Double, Double, Bool) -> Void
    private var first = true
    private var frames = 0
    private var intervalStart = 0.0
    init(update: @escaping (Int32, Int32, Double, Double, Bool) -> Void) { self.update = update }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let now = ProcessInfo.processInfo.systemUptime
        if first {
            first = false
            intervalStart = now
            update(size.width, size.height, 0, now, true)
            return
        }
        frames += 1
        let elapsed = now - intervalStart
        if elapsed >= 1 {
            update(size.width, size.height, Double(frames) / elapsed, now, false)
            frames = 0
            intervalStart = now
        }
    }
}

final class CaptureController: NSObject, ObservableObject {
    @Published var devices: [CaptureDeviceOption] = []
    @Published var audioDevices: [CaptureDeviceOption] = []
    @Published var phase: CapturePhase = .waiting
    @Published var message = "Connect your capture card to begin."
    @Published var deviceName = ""
    @Published var fps = 0.0
    @Published var resolution = ""
    @Published var audioStatus = "Audio unavailable"
    @Published var session: AVCaptureSession?
    let preferences: AppPreferences

    private let queue = DispatchQueue(label: "consoleview.capture", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "consoleview.metrics", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "consoleview.audio", qos: .userInteractive)
    private let lifetime = CaptureLifetime()
    private var preferenceSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private var configuration: CaptureConfiguration
    private var videoDevices: [AVCaptureDevice] = []
    private var availableAudio: [AVCaptureDevice] = []
    private var captureSession: AVCaptureSession?
    private var selectedVideo: AVCaptureDevice?
    private var selectedAudio: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureOutput?
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private var stereo: MS2109Audio?
    private var failedAudioID: String?
    private var metrics: VideoMetrics?
    private var watchdog: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var retryCount = 0
    private var preparing = false
    private var sleeping = false
    private var launched = false
    private var closed = false
    private var lastFrameTime = 0.0
    private var hasFrames = false
    private var displayAssertion: IOPMAssertionID = 0

    init(preferences: AppPreferences) {
        self.preferences = preferences
        configuration = CaptureConfiguration(preferences)
        super.init()
    }

    func launch() {
        if !launched {
            launched = true
            preferenceSubscription = preferences.objectWillChange.sink { [weak self] _ in
                // @Published sends before the new value has been stored.
                DispatchQueue.main.async { self?.settingsChanged() }
            }
            observeDevicesAndApplication()
        }
        guard !lifetime.wantsViewing else { return }
        start()
    }

    func start() {
        let config = CaptureConfiguration(preferences)
        let token = lifetime.advance(viewing: true)
        queue.async { [weak self] in
            guard let self, !self.closed, self.lifetime.matches(token) else { return }
            self.configuration = config
            self.retryCount = 0
            self.teardown(token: token)
            self.discover(token: token)
            self.connect(token: token)
        }
    }

    func stop() {
        let token = lifetime.advance(viewing: false)
        publish(token) { self.phase = .stopped; self.message = "Ready when you are."; self.session = nil }
        queue.async { [weak self] in
            guard let self, self.lifetime.matches(token) else { return }
            self.retryCount = 0
            self.teardown(token: token)
        }
    }

    func refreshDevices() {
        queue.async { [weak self] in self?.refreshAndConnect() }
    }

    func settingsChanged() {
        let config = CaptureConfiguration(preferences)
        queue.async { [weak self] in
            guard let self, !self.closed, config != self.configuration else { return }
            let rebuild = config.needsRebuild(from: self.configuration)
            self.configuration = config
            self.audioPreview?.volume = config.gain
            self.stereo?.setVolume(config.gain)
            if rebuild, let token = self.lifetime.advanceIfViewing() {
                self.failedAudioID = nil
                self.retryCount = 0
                self.teardown(token: token)
                self.discover(token: token)
                self.connect(token: token)
            }
        }
    }

    func chooseVideo(_ id: String) {
        preferences.videoID = id
        start()
    }

    func openPrivacySettings() {
        let pane = AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? "Privacy_Microphone" : "Privacy_Camera"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func shutdown() {
        preferenceSubscription = nil
        let token = lifetime.advance(viewing: false)
        queue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.teardown(token: token)
            self.observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
            self.observers.removeAll()
        }
    }

    private func publish(_ token: UInt64, _ changes: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard self?.lifetime.matches(token) == true else { return }
            changes()
        }
    }

    private func discover(token: UInt64) {
        videoDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            .filter { $0.isConnected && !$0.isContinuityCamera }
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
        availableAudio = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .filter { $0.isConnected && Self.isExternalAudio($0) }
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
        if let failedAudioID, !availableAudio.contains(where: { $0.uniqueID == failedAudioID }) { self.failedAudioID = nil }
        let videos = videoDevices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        let audio = availableAudio.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        publish(token) { self.devices = videos; self.audioDevices = audio }
    }

    private func refreshAndConnect() {
        guard !closed, !sleeping else { return }
        if captureSession == nil, !preparing, let token = lifetime.advanceIfViewing() {
            retry?.cancel(); retry = nil
            discover(token: token)
            connect(token: token)
        } else {
            // Do not invalidate a live stream or an in-flight permission request.
            discover(token: lifetime.current)
            // USB audio can appear after its video interface. Restore sound
            // when it arrives, or after permission is granted in Settings.
            if captureSession != nil, let video = selectedVideo, audioInput == nil,
               let audio = selectedAudioDevice(for: video), audio.uniqueID != failedAudioID,
               AVCaptureDevice.authorizationStatus(for: .audio) != .denied,
               AVCaptureDevice.authorizationStatus(for: .audio) != .restricted,
               let token = lifetime.advanceIfViewing() {
                teardown(token: token)
                discover(token: token)
                connect(token: token)
            }
        }
    }
    private var activeToken: UInt64 = 0

    private func connect(token: UInt64) {
        activeToken = token
        guard !closed, !sleeping, lifetime.matches(token), lifetime.wantsViewing, captureSession == nil, !preparing else { return }
        guard let id = CapturePolicy.selectedID(saved: configuration.videoID, available: videoDevices.map(\.uniqueID)),
              let video = videoDevices.first(where: { $0.uniqueID == id }) else {
            let multiple = configuration.videoID.isEmpty && videoDevices.count > 1
            let hasSavedChoice = !configuration.videoID.isEmpty
            publish(token) {
                self.phase = multiple ? .choosingSource : .waiting
                self.message = multiple ? "Choose the capture card you want to view." : hasSavedChoice ? "Your selected capture card isn’t connected." : "Connect your capture card to begin."
            }
            return
        }
        if configuration.videoID.isEmpty {
            configuration.videoID = id
            publish(token) { self.preferences.videoID = id }
        }
        selectedVideo = video
        preparing = true
        publish(token) { self.deviceName = video.localizedName; self.phase = .connecting; self.message = "Connecting to your capture card…" }
        authorizeVideo(video, token: token)
    }

    private func authorizeVideo(_ video: AVCaptureDevice, token: UInt64) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorizeAudio(video, token: token)
        case .notDetermined:
            publish(token) { self.phase = .requestingPermission; self.message = "Allow Camera access to view your capture card." }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.queue.async {
                    guard let self, self.lifetime.matches(token) else { return }
                    if granted { self.authorizeAudio(video, token: token) } else { self.cameraDenied(token: token) }
                }
            }
        default: cameraDenied(token: token)
        }
    }

    private func cameraDenied(token: UInt64) {
        preparing = false
        publish(token) { self.phase = .denied; self.message = "Allow Camera access in System Settings, then return here." }
    }

    private func authorizeAudio(_ video: AVCaptureDevice, token: UInt64) {
        guard lifetime.matches(token) else { return }
        let audio = selectedAudioDevice(for: video)
        guard let audio else {
            buildSession(video: video, audio: nil, paired: false, audioMessage: configuration.audioID == "off" ? "Audio off" : "Capture audio unavailable", token: token)
            return
        }
        let paired = automaticAudioDevice(for: video)?.uniqueID == audio.uniqueID
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            buildSession(video: video, audio: audio, paired: paired, audioMessage: "", token: token)
        case .notDetermined:
            publish(token) { self.phase = .requestingPermission; self.message = "Allow Microphone access for capture-card sound." }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.queue.async {
                    guard let self, self.lifetime.matches(token) else { return }
                    self.buildSession(video: video, audio: granted ? audio : nil, paired: paired, audioMessage: granted ? "" : "Audio permission denied", token: token)
                }
            }
        default:
            buildSession(video: video, audio: nil, paired: false, audioMessage: "Audio permission denied", token: token)
        }
    }

    private static func isExternalAudio(_ device: AVCaptureDevice) -> Bool {
        device.transportType != kAudioDeviceTransportTypeBuiltIn && device.transportType != 0 && !device.isContinuityCamera
    }

    private func selectedAudioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        if configuration.audioID == "off" { return nil }
        if configuration.audioID == "auto" { return automaticAudioDevice(for: video) }
        return availableAudio.first { $0.uniqueID == configuration.audioID }
    }

    private func automaticAudioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        let linked = video.linkedDevices.filter { $0.isConnected && $0.hasMediaType(.audio) && Self.isExternalAudio($0) }
        if linked.count == 1 { return linked[0] }
        if !linked.isEmpty { return nil }
        let candidates = availableAudio.filter { audio in
            guard audio.transportType == kAudioDeviceTransportTypeUSB else { return false }
            let name = audio.localizedName.lowercased()
            let captureLike = name.contains("digital audio") || name.contains("hdmi") || name.contains("capture")
            guard captureLike else { return false }
            let manufacturer = video.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let commonMaker = !manufacturer.isEmpty && manufacturer != "apple inc." && manufacturer != "apple" && manufacturer == audio.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let genericUSBPair = video.localizedName == "USB Video" && audio.localizedName == "USB Digital Audio" && CapturePolicy.isMS2109(modelID: video.modelID)
            return videoDevices.count == 1 && (commonMaker || genericUSBPair)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func buildSession(video: AVCaptureDevice, audio: AVCaptureDevice?, paired: Bool, audioMessage: String, token: UInt64) {
        guard lifetime.matches(token), lifetime.wantsViewing, video.isConnected else { preparing = false; return }
        let capture = AVCaptureSession()
        do {
            try configure(capture, video: video, audio: audio, paired: paired, audioMessage: audioMessage, token: token)
            guard lifetime.matches(token) else { preparing = false; stereo?.stop(); return }
            captureSession = capture
            selectedVideo = video
            observeSession(capture, token: token)
            publish(token) { self.session = capture; self.phase = .connecting; self.message = "Waiting for video from your capture card…" }
            capture.startRunning()
            preparing = false
            guard lifetime.matches(token) else { teardown(token: token); return }
            lastFrameTime = ProcessInfo.processInfo.systemUptime
            hasFrames = false
            startWatchdog(token: token)
        } catch {
            preparing = false
            teardown(token: token)
            reconnect(reason: error.localizedDescription, token: token)
        }
    }

    private func configure(_ capture: AVCaptureSession, video: AVCaptureDevice, audio: AVCaptureDevice?, paired: Bool, audioMessage: String, token: UInt64) throws {
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        let videoInput = try AVCaptureDeviceInput(device: video)
        guard capture.canAddInput(videoInput) else { throw CaptureError("This capture card is unavailable. Close other apps using it.") }
        capture.addInput(videoInput)
        try chooseFormat(video)
        let probe = VideoMetrics { [weak self] width, height, fps, time, first in
            self?.queue.async { self?.receivedFrame(width: width, height: height, fps: fps, time: time, first: first, token: token) }
        }
        metrics = probe
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        }
        output.setSampleBufferDelegate(probe, queue: videoQueue)
        guard capture.canAddOutput(output) else { throw CaptureError("This capture card cannot provide video frames.") }
        capture.addOutput(output)
        var status = audioMessage
        if let audio {
            do { status = try configureAudio(capture, video: video, audio: audio, paired: paired, token: token) }
            catch { removeAudio(from: capture); status = "Capture audio unavailable: \(error.localizedDescription)" }
        }
        publish(token) { self.audioStatus = status }
    }

    private func chooseFormat(_ device: AVCaptureDevice) throws {
        struct Candidate { let format: AVCaptureDevice.Format; let duration: CMTime; let mode: CapturePolicy.Format }
        let candidates = device.formats.compactMap { format -> Candidate? in
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }), range.maxFrameRate > 0 else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let mode = CapturePolicy.Format(width: dimensions.width, height: dimensions.height, fps: range.maxFrameRate, subtype: CMFormatDescriptionGetMediaSubType(format.formatDescription))
            return Candidate(format: format, duration: range.minFrameDuration, mode: mode)
        }
        guard let index = CapturePolicy.preferredFormatIndex(in: candidates.map(\.mode), quality: configuration.quality) else { throw CaptureError("No supported video format is available on this capture card.") }
        let selected = candidates[index]
        let requestedHeight: Int32? = configuration.quality == "720" ? 720 : configuration.quality == "1080" ? 1080 : nil
        if let requestedHeight, selected.mode.height != requestedHeight {
            configuration.quality = "auto"
            publish(activeToken) { self.preferences.quality = "auto" }
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selected.format
        device.activeVideoMinFrameDuration = selected.duration
        device.activeVideoMaxFrameDuration = selected.duration
    }

    private func configureAudio(_ capture: AVCaptureSession, video: AVCaptureDevice, audio: AVCaptureDevice, paired: Bool, token: UInt64) throws -> String {
        let input = try AVCaptureDeviceInput(device: audio)
        guard capture.canAddInput(input) else { throw CaptureError("The audio device is in use.") }
        capture.addInput(input)
        audioInput = input
        selectedAudio = audio
        let native = CMAudioFormatDescriptionGetStreamBasicDescription(audio.activeFormat.formatDescription)
        let correct = native.map { CapturePolicy.shouldCorrectMS2109(modelID: video.modelID, paired: paired, sampleRate: $0.pointee.mSampleRate, channels: $0.pointee.mChannelsPerFrame) } ?? false
        if correct {
            let playback = MS2109Audio()
            playback.onFailure = { [weak self] reason in self?.queue.async { self?.audioFailed(reason: reason, token: token) } }
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            guard capture.canAddOutput(output) else { throw CaptureError("Stereo correction is unavailable.") }
            capture.addOutput(output)
            audioOutput = output
            stereo = playback
            output.setSampleBufferDelegate(playback, queue: audioQueue)
            try playback.start(volume: configuration.gain)
            return "Stereo · MS2109 correction"
        }
        let output = AVCaptureAudioPreviewOutput()
        output.outputDeviceUniqueID = nil
        output.volume = configuration.gain
        guard capture.canAddOutput(output) else { throw CaptureError("Audio playback is unavailable.") }
        capture.addOutput(output)
        audioOutput = output
        audioPreview = output
        return audio.localizedName
    }

    private func receivedFrame(width: Int32, height: Int32, fps: Double, time: Double, first: Bool, token: UInt64) {
        guard lifetime.matches(token), captureSession != nil else { return }
        lastFrameTime = time
        if first {
            hasFrames = true
            retryCount = 0
            preventDisplaySleep()
        }
        publish(token) { self.resolution = "\(width) × \(height)"; self.fps = fps; self.phase = .live; self.message = "" }
    }

    private func startWatchdog(token: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.lifetime.matches(token), self.captureSession != nil else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastFrameTime
            if self.hasFrames && elapsed > 4 {
                self.reconnect(reason: "Video paused. Reconnecting to your capture card…", token: token)
            } else if !self.hasFrames && elapsed > 10 {
                self.publish(token) { self.phase = .waiting; self.message = "Waiting for video. Check console power and the HDMI connection." }
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func reconnect(reason: String, token: UInt64) {
        guard lifetime.matches(token), lifetime.wantsViewing else { return }
        guard let next = lifetime.advanceIfViewing() else { return }
        activeToken = next
        teardown(token: next)
        publish(next) { self.phase = .reconnecting; self.message = reason }
        let delay = CapturePolicy.retryDelay(attempt: retryCount)
        retryCount = min(retryCount + 1, 3)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lifetime.matches(next), self.lifetime.wantsViewing, !self.sleeping else { return }
            self.retry = nil
            self.discover(token: next)
            self.connect(token: next)
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardown(token: UInt64) {
        retry?.cancel(); retry = nil
        watchdog?.cancel(); watchdog = nil
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
        captureSession?.stopRunning()
        if let captureSession {
            for output in captureSession.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
        }
        captureSession = nil
        selectedVideo = nil
        selectedAudio = nil
        audioInput = nil
        audioOutput = nil
        audioPreview = nil
        stereo?.stop(); stereo = nil
        metrics = nil
        preparing = false
        hasFrames = false
        allowDisplaySleep()
        publish(token) { self.session = nil; self.fps = 0; self.resolution = ""; self.audioStatus = "Audio unavailable" }
    }

    private func removeAudio(from capture: AVCaptureSession) {
        if let output = audioOutput {
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            capture.removeOutput(output)
        }
        if let input = audioInput { capture.removeInput(input) }
        audioInput = nil; audioOutput = nil; audioPreview = nil; selectedAudio = nil
        stereo?.stop(); stereo = nil
    }

    private func audioFailed(reason: String, token: UInt64, retryWhenAvailable: Bool = false) {
        guard lifetime.matches(token), let captureSession else { return }
        if !retryWhenAvailable { failedAudioID = selectedAudio?.uniqueID }
        captureSession.beginConfiguration()
        removeAudio(from: captureSession)
        captureSession.commitConfiguration()
        publish(token) { self.audioStatus = reason }
    }

    private func observeSession(_ capture: AVCaptureSession, token: UInt64) {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: capture, queue: nil) { [weak self] notification in
                self?.queue.async {
                    guard let self, self.lifetime.matches(token), self.captureSession === capture else { return }
                    if name == AVCaptureSession.runtimeErrorNotification,
                       self.selectedVideo?.isConnected == true, self.selectedAudio?.isConnected == false {
                        self.audioFailed(reason: "Capture audio disconnected. Video is still available.", token: token, retryWhenAvailable: true)
                        if !capture.isRunning { capture.startRunning() }
                        return
                    }
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                    let reason = error?.localizedDescription ?? "Capture was interrupted. Reconnecting…"
                    self.reconnect(reason: reason, token: token)
                }
            }
            sessionObservers.append(observer)
        }
    }

    private func observeDevicesAndApplication() {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                self?.queue.async {
                    guard let self, !self.closed else { return }
                    if name == AVCaptureDevice.wasDisconnectedNotification, let device = notification.object as? AVCaptureDevice {
                        if device.uniqueID == self.selectedVideo?.uniqueID, self.selectedVideo?.isConnected == false {
                            self.reconnect(reason: "Your capture card was disconnected.", token: self.activeToken)
                        } else if device.uniqueID == self.selectedAudio?.uniqueID, self.selectedAudio?.isConnected == false {
                            self.audioFailed(reason: "Capture audio disconnected. Video is still available.", token: self.activeToken, retryWhenAvailable: true)
                        }
                    }
                    self.refreshAndConnect()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.refreshAndConnect() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.sleeping = true
                if let token = self.lifetime.advanceIfViewing() {
                    self.activeToken = token
                    self.teardown(token: token)
                    self.publish(token) { self.phase = .waiting; self.message = "Viewing resumes when your Mac wakes." }
                }
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.sleeping = false; self?.refreshAndConnect() }
        })
    }

    private func preventDisplaySleep() {
        guard displayAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Console View is displaying capture video" as CFString, &displayAssertion)
    }

    private func allowDisplaySleep() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }
}

private struct CaptureError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
