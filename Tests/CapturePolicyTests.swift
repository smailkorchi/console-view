import AVFoundation
import Foundation

@main
struct CapturePolicyTestRunner {
    static func main() {
        do {
            print("PASS: \(try CapturePolicyTests.run()) capture policy checks")
            print("PASS: \(try CaptureLifecycleTests.run()) capture lifecycle checks")
        }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}

enum CapturePolicyTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(message: message) }
            checks += 1
        }

        try check(CapturePolicy.selectedID(saved: "", available: []) == nil, "No card must remain waiting.")
        try check(CapturePolicy.selectedID(saved: "", available: ["card-a"]) == "card-a", "A single external card should connect automatically.")
        try check(CapturePolicy.selectedID(saved: "", available: ["card-a", "card-b"]) == nil, "Multiple cards must require a choice.")
        try check(CapturePolicy.selectedID(saved: "card-a", available: ["card-b", "card-a"]) == "card-a", "Restore the exact saved identifier.")
        try check(CapturePolicy.selectedID(saved: "missing-card", available: ["card-a"]) == nil, "A missing saved card must not silently switch to another card.")
        try check(CapturePolicy.selectedID(saved: "missing-card", available: ["card-a", "card-b"]) == nil, "A missing saved card must stay unavailable with multiple other cards.")
        try check(CapturePolicy.retryDelay(attempt: 0) == 1, "First recovery should wait one second, never loop immediately.")
        try check(CapturePolicy.retryDelay(attempt: 1) == 2 && CapturePolicy.retryDelay(attempt: 2) == 4, "Repeated failures should back off gradually.")
        try check(CapturePolicy.retryDelay(attempt: 3) == 8, "Recovery delay should reach eight seconds.")
        try check(CapturePolicy.retryDelay(attempt: 100) == 8, "Recovery must continue with bounded delay after many failures.")
        try check(CapturePolicy.retryDelay(attempt: Int.max) == 8, "Long-running automatic recovery must never overflow.")

        let affected = "UVC Camera VendorID_21325 ProductID_8457"
        try check(CapturePolicy.isMS2109(modelID: affected), "The known vendor/product pair should be recognized.")
        try check(!CapturePolicy.isMS2109(modelID: "VendorID_21325 ProductID_8458"), "Another MacroSilicon product must not enable the stereo patch.")
        try check(!CapturePolicy.isMS2109(modelID: "VendorID_213250 ProductID_8457"), "A vendor prefix is not an exact vendor identifier.")
        try check(!CapturePolicy.isMS2109(modelID: "VendorID_21325 ProductID_84570"), "A product prefix is not an exact product identifier.")
        try check(CapturePolicy.shouldCorrectMS2109(modelID: affected, paired: true, sampleRate: 96_000, channels: 1), "Confirmed paired 96 kHz mono hardware needs correction.")
        try check(!CapturePolicy.shouldCorrectMS2109(modelID: affected, paired: false, sampleRate: 96_000, channels: 1), "An unrelated mono microphone must not be reinterpreted as stereo.")
        try check(!CapturePolicy.shouldCorrectMS2109(modelID: "Apple Microphone", paired: true, sampleRate: 96_000, channels: 1), "The Mac microphone also supports 96 kHz mono and must be rejected.")
        try check(!CapturePolicy.shouldCorrectMS2109(modelID: affected, paired: true, sampleRate: 48_000, channels: 2), "Firmware-corrected native stereo must use the ordinary audio path.")
        try check(!CapturePolicy.shouldCorrectMS2109(modelID: "VendorID_21325 ProductID_8458", paired: true, sampleRate: 96_000, channels: 1), "Another product's mono descriptor does not prove the MS2109 defect.")

        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let raw = kCVPixelFormatType_422YpCbCr8_yuvs
        func mode(_ width: Int32, _ height: Int32, _ fps: Double, _ subtype: FourCharCode = nv12) -> CapturePolicy.Format {
            CapturePolicy.Format(width: width, height: height, fps: fps, subtype: subtype)
        }
        func selected(_ modes: [CapturePolicy.Format], _ quality: String = "auto") -> Int? {
            CapturePolicy.preferredFormatIndex(in: modes, quality: quality)
        }
        try check(selected([mode(3840, 2160, 30), mode(1920, 1080, 60)]) == 0, "Automatic mode must prefer 4K30 over 1080p60.")
        try check(selected([mode(1920, 1080, 30), mode(1280, 720, 60)]) == 0, "Automatic mode must prefer 1080p30 over 720p60.")
        try check(selected([mode(3840, 2160, 60), mode(3840, 2160, 120)]) == 1, "At the best resolution, choose its fastest supported rate.")
        try check(selected([mode(1920, 1080, 120), mode(1920, 1080, 240)]) == 1, "Supported frame rates above 120 fps must remain distinct and selectable.")
        try check(selected([mode(1920, 1080, 59.94), mode(1920, 1080, 60)]) == 1, "Fractional supported rates must not be rounded into a tie.")
        try check(selected([mode(1920, 1080, 60, raw), mode(1920, 1080, 60)]) == 1, "Equivalent resolution and rate should prefer NV12 over packed raw YUV.")
        try check(selected([mode(1920, 1080, 120, raw), mode(1920, 1080, 60)]) == 0, "Pixel-format preference must not override a faster supported rate.")
        try check(selected([mode(3840, 2160, 30, raw), mode(1920, 1080, 60)]) == 0, "Pixel-format preference must not override a larger supported image.")
        try check(selected([mode(3840, 1080, 30), mode(2560, 1440, 60)]) == 0, "Resolution must compare actual pixel area rather than height alone.")
        let choices = [mode(3840, 2160, 120), mode(1920, 1080, 60), mode(1280, 720, 30)]
        try check(selected(choices, "720") == 2, "Explicit 720p must retain its supported resolution even when larger modes are faster.")
        try check(selected(choices, "1080") == 1, "Explicit 1080p must retain its supported resolution even when 4K is faster.")
        try check(selected([mode(1280, 720, 30), mode(1280, 720, 60), mode(3840, 2160, 120)], "720") == 1, "Explicit resolution still chooses its fastest supported rate.")
        try check(selected([mode(3840, 2160, 30), mode(1280, 720, 120)], "1080") == 0, "An unavailable explicit resolution should fall back to the best supported image.")
        try check(selected([mode(-3840, -2160, 240), mode(1920, 1080, 30)]) == 1, "Nonpositive dimensions must never masquerade as a large valid pixel area.")
        try check(selected([mode(0, 1080, 240), mode(1920, 1080, 0)]) == nil, "A mode needs positive dimensions and a supported positive frame rate.")
        try check(selected([]) == nil, "An empty format inventory must have no selection.")

        let domain = "ConsoleView.PolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure(message: "Cannot create isolated preference domain.") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(defaults: defaults)
        try check(preferences.pictureMode == "fit", "The default picture must preserve every edge without cropping.")
        try check(preferences.showStats, "New users should see the delivered resolution and frame rate by default.")
        preferences.videoID = "saved-card"
        preferences.audioID = "off"
        preferences.showStats = false
        let restored = AppPreferences(defaults: defaults)
        try check(restored.videoID == "saved-card" && restored.audioID == "off", "Source choices must persist under the new app's domain.")
        try check(!restored.showStats, "An existing user's hidden statistics preference must remain unchanged.")
        return checks
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
