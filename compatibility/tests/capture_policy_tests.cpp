#include "capture_policy.h"
#include <cstdlib>
#include <iostream>
#include <limits>

static int checks = 0;
static void check(bool condition, const char *message) {
    ++checks;
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main() {
    check(!bestCaptureMode({}), "empty capabilities do not invent a mode");
    check(bestCaptureMode({{1920, 1080, 60}, {3840, 2160, 30}}) == 1, "4K30 takes priority over 1080p60");
    check(bestCaptureMode({{3840, 2160, 30}, {3840, 2160, 60}, {1920, 1080, 240}}) == 1, "fastest FPS at highest resolution");
    check(bestCaptureMode({{3840, 2160, 30}, {3840, 2160, 120}}) == 1, "no arbitrary 60 FPS cap");
    check(bestCaptureMode({{1280, 720, 60}, {1920, 1080, 30}}, 720) == 0, "explicit 720p preference remains explicit");
    check(bestCaptureMode({{1280, 720, 30}, {1280, 720, 120}}, 720) == 1, "manual resolution still uses fastest FPS");
    check(bestCaptureMode({{0, 1080, 60}, {1920, 1080, 30}}) == 1, "invalid dimensions excluded");
    check(!bestCaptureMode({{1920, 1080, -1}, {1920, 1080, std::numeric_limits<double>::infinity()}}), "invalid rates excluded");
    check(bestCaptureMode({{1920, 1080, 0}}) == 0, "unknown FPS does not discard real resolution");
    check(bestCaptureMode({{3840, 1080, 60}, {1920, 2160, 30}}) == 0, "equal pixel counts choose fastest mode");
    check(sourceCardAction(0) == SourceCardAction::Unavailable, "no source card disabled");
    check(sourceCardAction(1) == SourceCardAction::OpenSingle, "one source opens directly");
    check(sourceCardAction(2) == SourceCardAction::ChooseMultiple, "two sources show chooser");
    check(canAutoSelectSource(1, true, false), "one confirmed external source starts automatically");
    check(!canAutoSelectSource(1, false, false), "unknown transport requires an intentional click");
    check(!canAutoSelectSource(2, true, false), "multiple sources do not auto choose");
    check(!canAutoSelectSource(1, true, true), "missing saved device is not silently replaced");
    CaptureSession session;
    session.invalidate(); const auto first = session.generation;
    check(session.accepts(first), "current callback accepted while viewing");
    check(session.nextRetrySeconds() == 1 && session.nextRetrySeconds() == 2 && session.nextRetrySeconds() == 4, "automatic backoff");
    check(session.nextRetrySeconds() == 8 && session.nextRetrySeconds() == 8, "retry delay bounded at 8 seconds");
    session.stop();
    check(!session.viewing && !session.accepts(first), "Return Home rejects stale callbacks");
    check(session.retryAttempt == 0, "Return Home resets backoff");
    session.select(); const auto second = session.generation;
    check(session.viewing && session.accepts(second) && !session.accepts(first), "new source starts a fresh generation");
    session.invalidate();
    check(!session.accepts(second), "disconnect invalidates in-flight callbacks");
    std::cout << checks << " compatibility capture policy/lifecycle checks passed\n";
}
