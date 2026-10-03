import SwiftUI
import AVFoundation

enum CapturePhase: String {
    case waiting, choosingSource, requestingPermission, connecting, live
    case reconnecting, stopped, denied, failed
}

struct CaptureDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
}

final class AppPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var videoID: String { didSet { defaults.set(videoID, forKey: "videoID") } }
    @Published var audioID: String { didSet { defaults.set(audioID, forKey: "audioID") } }
    @Published var quality: String { didSet { defaults.set(quality, forKey: "quality") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var pictureMode: String { didSet { defaults.set(pictureMode, forKey: "pictureMode") } }
    @Published var volume: Float { didSet { defaults.set(volume, forKey: "volume") } }
    @Published var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }
    @Published var showStats: Bool { didSet { defaults.set(showStats, forKey: "showStats") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        videoID = defaults.string(forKey: "videoID") ?? ""
        audioID = defaults.string(forKey: "audioID") ?? "auto"
        quality = defaults.string(forKey: "quality") ?? "auto"
        appearance = defaults.string(forKey: "appearance") ?? "system"
        pictureMode = defaults.string(forKey: "pictureMode") ?? "fit"
        volume = defaults.object(forKey: "volume") as? Float ?? 0.8
        muted = defaults.bool(forKey: "muted")
        showStats = defaults.object(forKey: "showStats") as? Bool ?? true
    }

    var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
    var gravity: AVLayerVideoGravity {
        pictureMode == "fill" ? .resizeAspectFill : pictureMode == "stretch" ? .resize : .resizeAspect
    }
}

enum CapturePolicy {
    static func retryDelay(attempt: Int) -> Double {
        Double(1 << min(max(attempt, 0), 3))
    }

    static func selectedID(saved: String, available: [String]) -> String? {
        if !saved.isEmpty { return available.contains(saved) ? saved : nil }
        return available.count == 1 ? available[0] : nil
    }

    static func isMS2109(modelID: String) -> Bool {
        modelID.range(of: "VendorID_21325(?![0-9])", options: .regularExpression) != nil
            && modelID.range(of: "ProductID_8457(?![0-9])", options: .regularExpression) != nil
    }

    static func shouldCorrectMS2109(modelID: String, paired: Bool, sampleRate: Double, channels: UInt32) -> Bool {
        isMS2109(modelID: modelID) && paired && sampleRate == 96000 && channels == 1
    }

    struct Format {
        let width: Int32
        let height: Int32
        let fps: Double
        let subtype: FourCharCode
    }

    static func preferredFormatIndex(in formats: [Format], quality: String) -> Int? {
        let requestedHeight: Int32? = quality == "720" ? 720 : quality == "1080" ? 1080 : nil
        let eligible = formats.indices.filter { formats[$0].width > 0 && formats[$0].height > 0 && formats[$0].fps > 0 }
        let matching = eligible.filter { requestedHeight == nil || formats[$0].height == requestedHeight }
        return (matching.isEmpty ? eligible : matching).max { left, right in
            let lhs = formats[left], rhs = formats[right]
            let lhsArea = Int64(lhs.width) * Int64(lhs.height)
            let rhsArea = Int64(rhs.width) * Int64(rhs.height)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            if lhs.fps != rhs.fps { return lhs.fps < rhs.fps }
            let nv12 = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            return !nv12.contains(lhs.subtype) && nv12.contains(rhs.subtype)
        }
    }
}
