import Foundation
import Combine

enum CaptureLifecycleTests {
    static func run() throws -> Int {
        guard Thread.isMainThread else { throw Failure(message: "Lifecycle checks require the main run loop.") }
        let domain = "ConsoleView.LifecycleTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure(message: "Cannot create an isolated preference domain.") }
        defer { defaults.removePersistentDomain(forName: domain) }
        // This exact identifier cannot resolve to attached hardware, so launch
        // never reaches permission requests, capture inputs, or audio playback.
        let unavailableID = "unavailable-test-card-\(UUID().uuidString)"
        defaults.set(unavailableID, forKey: "videoID")
        defaults.set(false, forKey: "autoConnect")
        defaults.set(false, forKey: "autoReconnect")
        let preferences = AppPreferences(defaults: defaults)
        let controller = CaptureController(preferences: preferences)
        defer { controller.shutdown() }
        var checks = 0
        var discoveries = 0
        let discoverySubscription = controller.$devices.dropFirst().sink { _ in discoveries += 1 }
        defer { discoverySubscription.cancel() }

        func wait(_ message: String, until predicate: () -> Bool) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            repeat {
                if predicate() { checks += 1; return }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw Failure(message: message)
        }
        func waitForCard() -> Bool {
            controller.phase == .waiting && controller.message == "Your selected capture card isn’t connected." && controller.session == nil
        }

        controller.launch()
        try wait("Launch must automatically wait for its exact card despite old disabled flags.", until: waitForCard)
        let initialDiscoveries = discoveries
        try wait("A missing card must keep retrying discovery without another device notification.") { discoveries > initialDiscoveries }
        controller.launch()
        try wait("Launch must remain idempotent while viewing is already requested.", until: waitForCard)

        controller.stop()
        try wait("Returning Home must cancel capture intent.") { controller.phase == .stopped && controller.session == nil }
        let stoppedDiscoveries = discoveries
        let retryDeadline = ProcessInfo.processInfo.systemUptime + 2.2
        while ProcessInfo.processInfo.systemUptime < retryDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            guard discoveries == stoppedDiscoveries else { throw Failure(message: "A pending retry rediscovered devices after Return Home.") }
        }
        checks += 1
        guard controller.previewLayer.session == nil else { throw Failure(message: "A stopped controller kept its preview attached.") }
        checks += 1
        controller.launch()
        try wait("Reopening a stopped window must resume automatic viewing.", until: waitForCard)

        controller.stop()
        try wait("A second Return Home must stop viewing.") { controller.phase == .stopped }
        controller.chooseVideo(unavailableID)
        try wait("Selecting the same source after Return Home must resume viewing.", until: waitForCard)

        controller.stop()
        try wait("Final stop must clear the visible capture session.") { controller.phase == .stopped && controller.session == nil }
        controller.launch()
        controller.stop()
        controller.refreshDevices()
        preferences.quality = "720"
        preferences.volume = 0.3
        controller.settingsChanged()
        try wait("Stop must supersede queued launch and settings work.") { controller.phase == .stopped && controller.session == nil }
        let quietDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < quietDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            guard controller.phase == .stopped, controller.session == nil else {
                throw Failure(message: "Queued discovery or preference callbacks revived a stopped capture.")
            }
        }
        checks += 1
        return checks
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
