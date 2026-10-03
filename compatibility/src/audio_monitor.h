#pragma once
#include <QAudioDeviceInfo>
#include <QAudioInput>
#include <QAudioOutput>
#include <QByteArray>
#include <QIODevice>
#include <QMutex>
#include <QObject>
#include <functional>

class AudioRing final : public QIODevice {
public:
    explicit AudioRing(QObject *parent = nullptr) : QIODevice(parent) {}
    void reset(int capacity);
    qint64 bytesAvailable() const override;
    bool isSequential() const override { return true; }
protected:
    qint64 readData(char *data, qint64 length) override;
    qint64 writeData(const char *data, qint64 length) override;
private:
    mutable QMutex mutex;
    QByteArray buffer;
    int maximum = 0;
};
class AudioMonitor final : public QObject {
public:
    explicit AudioMonitor(QObject *parent = nullptr);
    ~AudioMonitor() override { stop(); }
    bool start(const QAudioDeviceInfo &input, qreal volume);
    void stop();
    void setVolume(qreal value);
    bool isRunning() const;
    std::function<void(const QString &)> statusChanged;
private:
    AudioRing ring;
    QAudioInput *input = nullptr;
    QAudioOutput *output = nullptr;
    bool outputStarted = false;
    int threshold = 0;
};
