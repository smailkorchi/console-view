#include "audio_monitor.h"
#include <QCoreApplication>
#include <cstdlib>
#include <iostream>

static int checks = 0;
static void check(bool condition, const char *message) {
    ++checks;
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    AudioRing ring;
    ring.reset(8); ring.open(QIODevice::ReadWrite | QIODevice::Unbuffered);
    check(ring.read(4).isEmpty(), "empty ring does not replay old samples");
    ring.write("abcd", 4);
    check(ring.bytesAvailable() == 4, "queued audio available");
    check(ring.read(2) == "ab", "partial read preserves order");
    check(ring.read(8) == "cd", "short read returns only real samples");
    ring.write("123456", 6); ring.write("7890", 4);
    check(ring.bytesAvailable() == 8, "latency queue remains bounded");
    check(ring.read(8) == "34567890", "overrun drops oldest audio to avoid accumulating latency");
    ring.write("abcdefghijkl", 12);
    check(ring.read(8) == "efghijkl", "single large write retains newest samples");
    ring.write("old", 3); ring.reset(8);
    check(ring.read(8).isEmpty(), "reconnect clears stale audio");
    ring.reset(0); ring.write("no", 2);
    check(ring.bytesAvailable() == 0, "stopped ring retains no samples");
    std::cout << checks << " compatibility audio buffer checks passed\n";
}
