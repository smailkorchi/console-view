#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <vector>

struct CaptureMode {
    int width = 0, height = 0;
    double framesPerSecond = 0;
};

inline std::optional<std::size_t> bestCaptureMode(const std::vector<CaptureMode> &modes, int preferredHeight = 0) {
    std::optional<std::size_t> best;
    for (std::size_t index = 0; index < modes.size(); ++index) {
        const auto &mode = modes[index];
        if (mode.width <= 0 || mode.height <= 0 || !std::isfinite(mode.framesPerSecond) || mode.framesPerSecond < 0) continue;
        if (!best) { best = index; continue; }
        const auto &current = modes[*best];
        if (preferredHeight > 0 && std::abs(mode.height - preferredHeight) != std::abs(current.height - preferredHeight)) {
            if (std::abs(mode.height - preferredHeight) < std::abs(current.height - preferredHeight)) best = index;
            continue;
        }
        const auto pixels = std::int64_t(mode.width) * mode.height;
        const auto currentPixels = std::int64_t(current.width) * current.height;
        if (pixels > currentPixels || (pixels == currentPixels && mode.framesPerSecond > current.framesPerSecond)) best = index;
    }
    return best;
}

enum class SourceCardAction { Unavailable, OpenSingle, ChooseMultiple };
inline SourceCardAction sourceCardAction(std::size_t sources) {
    return sources == 0 ? SourceCardAction::Unavailable : sources == 1 ? SourceCardAction::OpenSingle : SourceCardAction::ChooseMultiple;
}
inline bool canAutoSelectSource(std::size_t totalSources, bool soleSourceIsExternal, bool hasSavedSource) {
    return !hasSavedSource && totalSources == 1 && soleSourceIsExternal;
}

struct CaptureSession {
    bool viewing = true;
    std::uint64_t generation = 0;
    int retryAttempt = 0;
    bool accepts(std::uint64_t token) const { return viewing && token == generation; }
    void invalidate() { ++generation; }
    void select() { viewing = true; retryAttempt = 0; invalidate(); }
    void stop() { viewing = false; retryAttempt = 0; invalidate(); }
    int nextRetrySeconds() {
        const int seconds = 1 << std::min(retryAttempt, 3);
        retryAttempt = std::min(retryAttempt + 1, 3);
        return seconds;
    }
};
