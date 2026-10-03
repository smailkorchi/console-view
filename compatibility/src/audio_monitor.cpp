#include "audio_monitor.h"
#include <QMutexLocker>
#include <cstring>
#include <algorithm>

void AudioRing::reset(int capacity) {
    QMutexLocker guard(&mutex);
    buffer.clear(); maximum = capacity;
}
qint64 AudioRing::bytesAvailable() const {
    QMutexLocker guard(&mutex);
    return buffer.size() + QIODevice::bytesAvailable();
}
qint64 AudioRing::readData(char *data, qint64 length) {
    QMutexLocker guard(&mutex);
    const int count = int(std::min<qint64>(length, buffer.size()));
    std::memcpy(data, buffer.constData(), size_t(count));
    buffer.remove(0, count);
    return count;
}
qint64 AudioRing::writeData(const char *data, qint64 length) {
    {
        QMutexLocker guard(&mutex);
        const int count = int(std::min<qint64>(length, maximum));
        if (buffer.size() + count > maximum) buffer.remove(0, buffer.size() + count - maximum);
        buffer.append(data + length - count, count);
    }
    emit readyRead();
    return length;
}
AudioMonitor::AudioMonitor(QObject *parent) : QObject(parent), ring(this) {
    connect(&ring, &QIODevice::readyRead, this, [this] {
        if (output && !outputStarted && ring.bytesAvailable() >= threshold) {
            outputStarted = true;
            output->start(&ring);
            if (output->error() != QAudio::NoError && statusChanged) statusChanged("Audio output is unavailable. Retrying automatically.");
        }
    });
}
bool AudioMonitor::start(const QAudioDeviceInfo &device, qreal volume) {
    stop();
    const QAudioDeviceInfo destination = QAudioDeviceInfo::defaultOutputDevice();
    if (device.isNull() || destination.isNull()) {
        if (statusChanged) statusChanged("Audio input or output is unavailable. Retrying automatically.");
        return false;
    }
    QAudioFormat format;
    bool found = false;
    for (int rate : {48000, 44100}) {
        for (int channels : {2, 1}) {
            format.setCodec("audio/pcm"); format.setSampleRate(rate); format.setChannelCount(channels);
            format.setSampleSize(16); format.setSampleType(QAudioFormat::SignedInt); format.setByteOrder(QAudioFormat::LittleEndian);
            if (device.isFormatSupported(format) && destination.isFormatSupported(format)) { found = true; break; }
        }
        if (found) break;
    }
    if (!found) {
        if (statusChanged) statusChanged("This input and audio output have no common supported PCM format.");
        return false;
    }
    const int bytesPerSecond = format.sampleRate() * format.channelCount() * format.sampleSize() / 8;
    ring.reset(bytesPerSecond / 10);
    ring.open(QIODevice::ReadWrite | QIODevice::Unbuffered);
    threshold = bytesPerSecond / 50;
    input = new QAudioInput(device, format, this);
    output = new QAudioOutput(destination, format, this);
    input->setBufferSize(bytesPerSecond / 25);
    output->setBufferSize(bytesPerSecond / 25);
    output->setVolume(volume);
    connect(input, &QAudioInput::stateChanged, this, [this](QAudio::State state) {
        if (input && state == QAudio::StoppedState && input->error() != QAudio::NoError && statusChanged)
            statusChanged("The selected audio input is unavailable. Retrying automatically.");
    });
    input->start(&ring);
    if (input->error() != QAudio::NoError) {
        if (statusChanged) statusChanged("The selected audio input is unavailable. Retrying automatically.");
        return false;
    }
    if (statusChanged) statusChanged("Audio: " + device.deviceName());
    return true;
}
void AudioMonitor::stop() {
    outputStarted = false;
    if (input) { input->stop(); delete input; input = nullptr; }
    if (output) { output->stop(); delete output; output = nullptr; }
    ring.close(); ring.reset(0);
}
void AudioMonitor::setVolume(qreal value) { if (output) output->setVolume(value); }
bool AudioMonitor::isRunning() const {
    return input && output && input->state() != QAudio::StoppedState && input->error() == QAudio::NoError && output->error() == QAudio::NoError;
}
