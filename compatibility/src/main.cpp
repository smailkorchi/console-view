#include "audio_monitor.h"
#include "capture_policy.h"
#include "device_identity.h"
#include <QActionGroup>
#include <QApplication>
#include <QCamera>
#include <QCameraViewfinder>
#include <QCameraViewfinderSettings>
#include <QCloseEvent>
#include <QComboBox>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QElapsedTimer>
#include <QEvent>
#include <QFormLayout>
#include <QLabel>
#include <QMainWindow>
#include <QMenu>
#include <QMenuBar>
#include <QPainter>
#include <QPointer>
#include <QPushButton>
#include <QSettings>
#include <QShortcut>
#include <QSlider>
#include <QStackedWidget>
#include <QStyle>
#include <QSvgRenderer>
#include <QTimer>
#include <QToolButton>
#include <QUrl>
#include <QVideoProbe>
#include <QVBoxLayout>
#include <algorithm>
#include <iostream>

struct CaptureSource {
    QCameraInfo camera;
    CameraIdentity identity;
};

class ConsoleWindow final : public QMainWindow {
public:
    explicit ConsoleWindow(bool enableCapture = true) : preferences("ElQorchiIsmail", "ConsoleViewCompatibility"), audio(this), systemPalette(qApp->palette()) {
        setWindowTitle("Console View");
        setWindowIcon(QIcon(":/AppIcon.png"));
        resize(900, 620); setMinimumSize(640, 500);
        selectedId = preferences.value("videoSource").toString();
        audioName = preferences.value("audioSource").toString();
        volume = preferences.value("volume", 80).toInt();
        buildInterface();
        applyAppearance();
        audio.statusChanged = [this](const QString &text) { updateAudioStatus(text); };
        discovery.setInterval(1000);
        connect(&discovery, &QTimer::timeout, this, [this] { refreshSources(); });
        retry.setSingleShot(true);
        connect(&retry, &QTimer::timeout, this, [this] { connectSelected(); });
        startupTimeout.setSingleShot(true);
        connect(&startupTimeout, &QTimer::timeout, this, [this] { if (camera) recover("The capture card did not start. Trying again automatically."); });
        if (enableCapture) {
            discovery.start();
            QTimer::singleShot(0, this, [this] { refreshSources(); });
        }
    }
    ~ConsoleWindow() override { teardown(); audio.stop(); }
    bool smokeCheck() {
        const bool homeReady = !sourceWell->isEnabled() && !returnHomeAction->isEnabled();
        pages->setCurrentWidget(viewer); reconnecting = true; updateViewerChrome();
        const bool windowed = !viewerControls->isHidden() && !recoveryTitle->isHidden();
        showFullScreen(); updateViewerChrome();
        const bool fullscreen = viewerControls->isHidden() && recoveryTitle->isHidden() && recoveryDetail->isHidden();
        showNormal(); updateViewerChrome();
        const bool restored = !viewerControls->isHidden() && !recoveryTitle->isHidden();
        returnHome();
        return homeReady && windowed && fullscreen && restored && !session.viewing && pages->currentWidget() == home;
    }
protected:
    void closeEvent(QCloseEvent *event) override {
        session.stop(); discovery.stop(); retry.stop(); teardown();
        QMainWindow::closeEvent(event);
    }
    void changeEvent(QEvent *event) override {
        QMainWindow::changeEvent(event);
        if (event->type() == QEvent::WindowStateChange && pages) updateViewerChrome();
    }
private:
    QSettings preferences;
    AudioMonitor audio;
    QPalette systemPalette;
    QList<CaptureSource> sources;
    QString selectedId, activeId, audioName, audioStatus;
    int volume = 80, frameCount = 0;
    bool wasActive = false, muted = false, reconnecting = false;
    CaptureSession session;
    QPointer<QCamera> camera;
    QPointer<QVideoProbe> probe;
    QElapsedTimer frameClock;
    QTimer discovery, retry, startupTimeout;
    QStackedWidget *pages = nullptr;
    QWidget *home = nullptr, *viewer = nullptr;
    QWidget *viewerControls = nullptr;
    QCameraViewfinder *viewfinder = nullptr;
    QLabel *homeStatus = nullptr, *recoveryTitle = nullptr, *recoveryDetail = nullptr, *captureInfo = nullptr;
    QPointer<QLabel> audioStatusLabel;
    QPushButton *muteButton = nullptr;
    QSlider *volumeSlider = nullptr;
    QPushButton *sourceWell = nullptr, *privacy = nullptr;
    QAction *returnHomeAction = nullptr, *fullscreenAction = nullptr;
    QMenu *sourceMenu = nullptr;

    QPixmap appPixmap(int size) const {
        QPixmap pixmap = QPixmap(":/AppIcon.png").scaled(QSize(size, size) * devicePixelRatioF(), Qt::KeepAspectRatio, Qt::SmoothTransformation);
        pixmap.setDevicePixelRatio(devicePixelRatioF());
        return pixmap;
    }

    static QIcon brandIcon(const QString &resource, const QColor &color) {
        QSvgRenderer renderer(resource);
        QPixmap pixmap(64, 64); pixmap.fill(Qt::transparent);
        QPainter painter(&pixmap);
        renderer.render(&painter);
        painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
        painter.fillRect(pixmap.rect(), color);
        return QIcon(pixmap);
    }
    void buildInterface() {
        sourceMenu = new QMenu("Change Source", this);
        connect(sourceMenu, &QMenu::aboutToShow, this, [this] { rebuildSourceMenu(); });
        auto *appMenu = menuBar()->addMenu("Console View");
        appMenu->addAction("About Console View", this, [this] { showAbout(); });
        appMenu->addAction("Settings…", this, [this] { showSettings(); }, QKeySequence::Preferences);
        appMenu->addSeparator();
        appMenu->addAction("Quit", qApp, &QApplication::quit, QKeySequence::Quit);
        auto *captureMenu = menuBar()->addMenu("Capture");
        captureMenu->addMenu(sourceMenu);
        returnHomeAction = captureMenu->addAction("Return Home", this, [this] { returnHome(); });
        auto *viewMenu = menuBar()->addMenu("View");
        fullscreenAction = viewMenu->addAction("Full Screen", this, [this] { isFullScreen() ? showNormal() : showFullScreen(); }, QKeySequence("F"));
        fullscreenAction->setCheckable(true);
        auto *pictureMenu = viewMenu->addMenu("Picture Size");
        auto *pictureGroup = new QActionGroup(this);
        const QStringList sizes{"Fit", "Fill", "Stretch"};
        for (int value = 0; value < sizes.size(); ++value) {
            auto *action = pictureMenu->addAction(sizes[value]); action->setCheckable(true); pictureGroup->addAction(action);
            action->setChecked(preferences.value("picture", 0).toInt() == value);
            connect(action, &QAction::triggered, this, [this, value] { preferences.setValue("picture", value); applyPicture(); });
        }
        auto *escape = new QShortcut(QKeySequence(Qt::Key_Escape), this);
        connect(escape, &QShortcut::activated, this, [this] { if (isFullScreen()) showNormal(); });
        auto *mute = new QShortcut(QKeySequence("M"), this);
        connect(mute, &QShortcut::activated, this, [this] { muteButton->setChecked(!muteButton->isChecked()); });

        pages = new QStackedWidget; setCentralWidget(pages);
        home = new QWidget; home->setObjectName("home");
        auto *column = new QVBoxLayout(home);
        column->setContentsMargins(40, 40, 40, 40); column->setSpacing(0);
        column->addStretch();
        auto *icon = new QLabel;
        icon->setPixmap(appPixmap(88));
        icon->setAlignment(Qt::AlignCenter); column->addWidget(icon);
        auto *title = new QLabel("Console View");
        QFont titleFont = font(); titleFont.setPointSize(28); titleFont.setWeight(QFont::DemiBold);
        title->setFont(titleFont); title->setAlignment(Qt::AlignCenter);
        column->addSpacing(20); column->addWidget(title);
        auto *subtitle = new QLabel("Your console. Your computer.");
        subtitle->setAlignment(Qt::AlignCenter); subtitle->setObjectName("secondary");
        column->addSpacing(7); column->addWidget(subtitle);
        sourceWell = new QPushButton("No capture device\nConnect an HDMI capture card");
        sourceWell->setObjectName("sourceWell"); sourceWell->setFixedSize(360, 58);
        sourceWell->setAccessibleName("View capture source"); sourceWell->setEnabled(false);
        sourceWell->setCursor(Qt::PointingHandCursor);
        connect(sourceWell, &QPushButton::clicked, this, [this] {
            if (sourceCardAction(std::size_t(sources.size())) == SourceCardAction::OpenSingle) selectSource(sources.first().identity.stableId);
            else if (sources.size() > 1) { rebuildSourceMenu(); sourceMenu->popup(sourceWell->mapToGlobal(QPoint(0, sourceWell->height()))); }
        });
        column->addSpacing(25); column->addWidget(sourceWell, 0, Qt::AlignHCenter);
        privacy = new QPushButton("Open Privacy Settings");
        connect(privacy, &QPushButton::clicked, this, [] { QDesktopServices::openUrl(QUrl(cameraPrivacyUrl())); });
        privacy->setVisible(false); column->addSpacing(14); column->addWidget(privacy, 0, Qt::AlignHCenter);
        auto *help = new QPushButton("Connection Help");
        help->setFlat(true);
        connect(help, &QPushButton::clicked, this, [this] { showHelp(); });
        column->addSpacing(12); column->addWidget(help, 0, Qt::AlignHCenter);
        homeStatus = new QLabel("Waiting for a capture card");
        homeStatus->setObjectName("secondary"); homeStatus->setAlignment(Qt::AlignCenter); homeStatus->setWordWrap(true);
        column->addSpacing(20); column->addWidget(homeStatus); column->addStretch();
        pages->addWidget(home);

        viewer = new QWidget; viewer->setObjectName("viewer");
        auto *viewerLayout = new QVBoxLayout(viewer); viewerLayout->setContentsMargins(0, 0, 0, 0); viewerLayout->setSpacing(0);
        recoveryTitle = new QLabel; recoveryTitle->setAlignment(Qt::AlignCenter);
        recoveryDetail = new QLabel; recoveryDetail->setAlignment(Qt::AlignCenter); recoveryDetail->setWordWrap(true);
        viewerLayout->addWidget(recoveryTitle); viewerLayout->addWidget(recoveryDetail);
        viewfinder = new QCameraViewfinder; viewerLayout->addWidget(viewfinder, 1);
        viewerControls = new QWidget; viewerControls->setObjectName("viewerControls");
        auto *controls = new QHBoxLayout(viewerControls); controls->setContentsMargins(20, 8, 20, 12);
        controls->addStretch();
        muteButton = new QPushButton("Mute");
        muteButton->setCheckable(true);
        connect(muteButton, &QPushButton::toggled, this, [this](bool value) { muted = value; audio.setVolume(muted ? 0 : volume / 100.0); });
        controls->addWidget(muteButton);
        volumeSlider = new QSlider(Qt::Horizontal); volumeSlider->setRange(0, 100); volumeSlider->setValue(volume); volumeSlider->setFixedWidth(100);
        volumeSlider->setAccessibleName("Volume");
        connect(volumeSlider, &QSlider::valueChanged, this, [this](int value) { volume = value; preferences.setValue("volume", value); audio.setVolume(muted ? 0 : value / 100.0); });
        controls->addWidget(volumeSlider);
        auto *picture = new QComboBox; picture->addItems({"Fit", "Fill", "Stretch"});
        picture->setCurrentIndex(preferences.value("picture", 0).toInt());
        connect(picture, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int value) { preferences.setValue("picture", value); applyPicture(); });
        controls->addWidget(picture);
        captureInfo = new QLabel("Capture statistics unavailable"); captureInfo->setWordWrap(true); controls->addWidget(captureInfo);
        controls->addStretch(); viewerLayout->addWidget(viewerControls);
        pages->addWidget(viewer); applyPicture(); showHome();
    }
    void updateViewerChrome() {
        const bool full = isFullScreen();
        viewerControls->setVisible(!full && pages->currentWidget() == viewer);
        recoveryTitle->setVisible(reconnecting && !full);
        recoveryDetail->setVisible(reconnecting && !full);
        fullscreenAction->setChecked(full);
#if !defined(Q_OS_MACOS)
        menuBar()->setVisible(!full);
#endif
    }
    void applyPicture() {
        const int picture = preferences.value("picture", 0).toInt();
        viewfinder->setAspectRatioMode(picture == 1 ? Qt::KeepAspectRatioByExpanding : picture == 2 ? Qt::IgnoreAspectRatio : Qt::KeepAspectRatio);
    }
    void applyAppearance() {
        const QString appearance = preferences.value("appearance", "system").toString();
        QPalette palette = systemPalette;
        if (appearance == "dark") {
            palette.setColor(QPalette::Window, QColor(29, 32, 36)); palette.setColor(QPalette::WindowText, Qt::white);
            palette.setColor(QPalette::Base, QColor(34, 37, 41)); palette.setColor(QPalette::Text, Qt::white);
            palette.setColor(QPalette::Button, QColor(46, 49, 54)); palette.setColor(QPalette::ButtonText, Qt::white);
            palette.setColor(QPalette::Highlight, QColor(0, 122, 255)); palette.setColor(QPalette::HighlightedText, Qt::white);
        } else if (appearance == "light") {
            palette = style()->standardPalette();
        }
        qApp->setPalette(palette);
        const bool dark = palette.color(QPalette::Window).lightness() < 128;
        setStyleSheet(QString("QWidget#home {background:%1;} QLabel#secondary {color:%2;} QPushButton#sourceWell {border:1px solid %3; border-radius:12px; padding:10px; text-align:left;} QWidget#viewer {background:black;} QWidget#viewer QLabel {color:white;}")
            .arg(dark ? "#1d2024" : "#f8f7f5", dark ? "#bbc0c8" : "#60646b", dark ? "#474b52" : "#d8d8da"));
    }
    void refreshSources() {
        QList<CaptureSource> current;
        for (const QCameraInfo &info : QCameraInfo::availableCameras()) {
            const CameraIdentity identity = identifyCamera(info);
            if (identity.transport != CameraTransport::BuiltIn) current.append({info, identity});
        }
        const bool changed = sources.size() != current.size() || !std::equal(sources.begin(), sources.end(), current.begin(), [](const CaptureSource &left, const CaptureSource &right) { return left.identity.stableId == right.identity.stableId && left.camera.description() == right.camera.description(); });
        sources = current;
        if (sourceMenu->isVisible() && sources.size() < 2) sourceMenu->hide();
        else if (sourceMenu->isVisible() && changed) rebuildSourceMenu();
        updateHomeSource();
        if (!session.viewing) return;
        if (camera && std::none_of(sources.begin(), sources.end(), [this](const CaptureSource &source) { return source.identity.stableId == activeId; })) {
            recover("Capture card disconnected. Reconnect it to continue.");
        }
        if (camera) {
            if (camera->status() == QCamera::ActiveStatus && !audioName.isEmpty() && !audio.isRunning()) startAudio();
            return;
        }
        if (retry.isActive()) return;
        connectSelected();
    }
    void updateHomeSource() {
        sourceWell->setEnabled(!sources.isEmpty());
        if (sources.size() == 1) sourceWell->setText(sources.first().camera.description() + "\nClick to view →");
        else sourceWell->setText(sources.isEmpty() ? "No capture device\nConnect an HDMI capture card" : QString("Choose a capture source →\n%1 sources available").arg(sources.size()));
        sourceWell->setToolTip(sources.size() == 1 ? "View this capture source" : "Choose the source connected to your console");
    }
    void rebuildSourceMenu() {
        sourceMenu->clear();
        if (sources.isEmpty()) {
            sourceMenu->addAction("No capture cards connected")->setEnabled(false);
            return;
        }
        for (const CaptureSource &source : sources) {
            auto *action = sourceMenu->addAction("View " + source.camera.description());
            action->setCheckable(true); action->setChecked(source.identity.stableId == selectedId);
            const QString id = source.identity.stableId;
            connect(action, &QAction::triggered, this, [this, id] { selectSource(id); });
        }
    }
    void selectSource(const QString &id) {
        selectedId = id; preferences.setValue("videoSource", id);
        session.select(); retry.stop(); teardown(); connectSelected();
    }
    void connectSelected() {
        if (!session.viewing || camera) return;
        if (canAutoSelectSource(std::size_t(sources.size()), sources.size() == 1 && sources.first().identity.transport == CameraTransport::External, !selectedId.isEmpty())) {
            selectedId = sources.first().identity.stableId; preferences.setValue("videoSource", selectedId); updateHomeSource();
        }
        const auto selected = std::find_if(sources.begin(), sources.end(), [this](const CaptureSource &source) { return source.identity.stableId == selectedId; });
        if (selected == sources.end()) {
            homeStatus->setText(sources.isEmpty() ? "Waiting for a capture card" : "Choose your capture source");
            if (wasActive) {
                reconnecting = true; recoveryTitle->setText("Reconnecting");
                recoveryDetail->setText("Reconnect your capture card. Viewing resumes automatically."); updateViewerChrome();
            }
            return;
        }
        if (cameraPermissionDenied()) {
            showHome(); privacy->show(); homeStatus->setText("Allow Camera access in your system privacy settings.");
            return;
        }
        privacy->hide(); activeId = selectedId;
        session.invalidate(); const auto token = session.generation;
        camera = new QCamera(selected->camera, this);
        camera->setCaptureMode(QCamera::CaptureViewfinder); camera->setViewfinder(viewfinder);
        probe = new QVideoProbe(this);
        if (probe->setSource(camera)) {
            connect(probe, &QVideoProbe::videoFrameProbed, this, [this, token](const QVideoFrame &frame) {
                if (!session.accepts(token) || !camera || !frame.isValid()) return;
                if (!frameClock.isValid()) { frameClock.start(); frameCount = 0; return; }
                ++frameCount;
                const auto elapsed = frameClock.elapsed();
                if (elapsed >= 2000) {
                    captureInfo->setText(QString("%1 × %2 · %3 fps measured").arg(frame.width()).arg(frame.height()).arg(frameCount * 1000.0 / elapsed, 0, 'f', 1));
                    frameCount = 0; frameClock.restart();
                }
            });
        } else { delete probe; probe = nullptr; }
        homeStatus->setText("Connecting to " + selected->camera.description());
        connect(camera, &QCamera::statusChanged, this, [this, token](QCamera::Status status) {
            if (!session.accepts(token) || !camera) return;
            if (status == QCamera::LoadedStatus) { configureViewfinder(); camera->start(); }
            if (status == QCamera::ActiveStatus) {
                startupTimeout.stop(); session.retryAttempt = 0; wasActive = true; reconnecting = false; pages->setCurrentWidget(viewer);
                returnHomeAction->setEnabled(true); updateViewerChrome();
                const auto reported = camera->viewfinderSettings();
                if (reported.resolution().isValid()) {
                    const QString rate = reported.maximumFrameRate() > 0 ? QString("up to %1 fps configured").arg(reported.maximumFrameRate(), 0, 'g', 4) : "frame rate unavailable";
                    captureInfo->setText(QString("%1 × %2 · %3").arg(reported.resolution().width()).arg(reported.resolution().height()).arg(rate));
                }
                else captureInfo->setText("Capture statistics unavailable");
                startAudio();
            }
        });
        connect(camera, QOverload<QCamera::Error>::of(&QCamera::error), this, [this, token](QCamera::Error error) {
            if (error != QCamera::NoError && session.accepts(token) && camera) recover(camera->errorString());
        });
        startupTimeout.start(20000);
        camera->load();
    }
    void configureViewfinder() {
        const auto formats = camera->supportedViewfinderSettings();
        if (formats.isEmpty()) return;
        std::vector<CaptureMode> modes;
        for (const auto &format : formats) modes.push_back({format.resolution().width(), format.resolution().height(), format.maximumFrameRate()});
        const auto best = bestCaptureMode(modes, preferences.value("quality", 0).toInt() == 720 ? 720 : 0);
        if (!best) return;
        auto settings = formats[int(*best)];
        if (settings.maximumFrameRate() > 0) settings.setMinimumFrameRate(settings.maximumFrameRate());
        camera->setViewfinderSettings(settings);
    }
    void recover(const QString &reason) {
        teardown();
        if (!session.viewing) return;
        const int seconds = session.nextRetrySeconds();
        const QString detail = reason.isEmpty() ? "Waiting for the capture card to become available." : reason;
        if (wasActive) {
            pages->setCurrentWidget(viewer); reconnecting = true; recoveryTitle->setText("Reconnecting");
            recoveryDetail->setText(detail + QString("\nReconnecting automatically in %1 seconds.").arg(seconds)); updateViewerChrome();
        } else homeStatus->setText(detail + QString(" Reconnecting automatically in %1 seconds.").arg(seconds));
        retry.start(seconds * 1000);
    }
    void teardown() {
        session.invalidate(); startupTimeout.stop(); frameClock.invalidate(); frameCount = 0;
        audio.stop();
        if (probe) { probe->setSource(static_cast<QMediaObject *>(nullptr)); probe->deleteLater(); probe = nullptr; }
        if (camera) {
            QCamera *old = camera; camera = nullptr;
            old->disconnect(this); old->stop(); old->unload(); old->deleteLater();
        }
        activeId.clear();
    }
    void showHome() {
        pages->setCurrentWidget(home); returnHomeAction->setEnabled(false); reconnecting = false; updateViewerChrome();
    }
    void returnHome() {
        session.stop(); retry.stop(); teardown(); wasActive = false;
        if (isFullScreen()) showNormal();
        showHome(); updateHomeSource(); homeStatus->setText("Select a source to view again.");
    }
    void startAudio() {
        if (!camera || camera->status() != QCamera::ActiveStatus || audioName.isEmpty()) { audio.stop(); updateAudioStatus("Select the capture card’s audio input in Settings."); return; }
        QList<QAudioDeviceInfo> matching;
        for (const QAudioDeviceInfo &device : QAudioDeviceInfo::availableDevices(QAudio::AudioInput)) if (device.deviceName() == audioName) matching.append(device);
        if (matching.size() == 1) audio.start(matching.first(), muted ? 0 : volume / 100.0);
        else { audio.stop(); updateAudioStatus("The saved audio input is missing or ambiguous. Reconnect it, or choose a uniquely named input in Settings."); }
    }
    void updateAudioStatus(const QString &text) {
        audioStatus = text;
        if (audioStatusLabel) audioStatusLabel->setText(text);
    }
    void showSettings() {
        QDialog dialog(this); dialog.setWindowTitle("Settings"); dialog.setMinimumWidth(460);
        auto *form = new QFormLayout(&dialog); form->setContentsMargins(25, 25, 25, 25);
        auto *appearance = new QComboBox; appearance->addItem("System", "system"); appearance->addItem("Light", "light"); appearance->addItem("Dark", "dark");
        appearance->setCurrentIndex(appearance->findData(preferences.value("appearance", "system")));
        form->addRow("Appearance", appearance);
        connect(appearance, QOverload<int>::of(&QComboBox::currentIndexChanged), &dialog, [this, appearance] { preferences.setValue("appearance", appearance->currentData()); applyAppearance(); });
        auto *video = new QComboBox; video->addItem("Choose a capture source", QString());
        for (const CaptureSource &source : sources) video->addItem(source.camera.description(), source.identity.stableId);
        video->setCurrentIndex(std::max(0, video->findData(selectedId))); form->addRow("Video source", video);
        connect(video, QOverload<int>::of(&QComboBox::activated), &dialog, [this, video] {
            if (video->currentData().toString().isEmpty()) return;
            selectSource(video->currentData().toString());
        });
        auto *input = new QComboBox; input->addItem("Off", QString());
        for (const QAudioDeviceInfo &device : QAudioDeviceInfo::availableDevices(QAudio::AudioInput)) input->addItem(device.deviceName(), device.deviceName());
        input->setCurrentIndex(std::max(0, input->findData(audioName))); form->addRow("Audio input", input);
        connect(input, QOverload<int>::of(&QComboBox::activated), &dialog, [this, input] { audioName = input->currentData().toString(); preferences.setValue("audioSource", audioName); startAudio(); });
        auto *audioHint = new QLabel("Select the capture card’s audio input. Audio is off until you choose an input."); audioHint->setWordWrap(true); form->addRow(audioHint);
        audioStatusLabel = new QLabel(audioStatus); audioStatusLabel->setWordWrap(true); form->addRow(audioStatusLabel);
        auto *level = new QSlider(Qt::Horizontal); level->setRange(0, 100); level->setValue(volume); form->addRow("Volume", level);
        connect(level, &QSlider::valueChanged, &dialog, [this](int value) { volumeSlider->setValue(value); });
        auto *quality = new QComboBox; quality->addItem("Automatic — highest resolution, fastest FPS", 0); quality->addItem("Prefer 720p", 720);
        quality->setCurrentIndex(preferences.value("quality", 0).toInt() == 720 ? 1 : 0); form->addRow("Capture quality", quality);
        connect(quality, QOverload<int>::of(&QComboBox::currentIndexChanged), &dialog, [this, quality] { preferences.setValue("quality", quality->currentData()); if (session.viewing) { retry.stop(); teardown(); connectSelected(); } });
        auto *picture = new QComboBox; picture->addItems({"Fit — full picture", "Fill — cropped edges", "Stretch — changed proportions"}); picture->setCurrentIndex(preferences.value("picture", 0).toInt()); form->addRow("Picture size", picture);
        connect(picture, QOverload<int>::of(&QComboBox::currentIndexChanged), &dialog, [this, picture] { preferences.setValue("picture", picture->currentIndex()); applyPicture(); });
        auto *privacyButton = new QPushButton("Camera Privacy Settings");
        if (!cameraPrivacyUrl().isEmpty()) { form->addRow(privacyButton); connect(privacyButton, &QPushButton::clicked, &dialog, [] { QDesktopServices::openUrl(QUrl(cameraPrivacyUrl())); }); }
        else delete privacyButton;
        auto *done = new QDialogButtonBox(QDialogButtonBox::Close); form->addRow(done); connect(done, &QDialogButtonBox::rejected, &dialog, &QDialog::accept);
        dialog.exec();
    }
    void showHelp() {
        QDialog dialog(this); dialog.setWindowTitle("Connect Your Console");
        auto *layout = new QVBoxLayout(&dialog); layout->setContentsMargins(28, 28, 28, 28);
        auto *text = new QLabel("Connect the capture card’s USB cable to your computer. Connect your console to the card’s HDMI input, then turn on the console.\n\nA single identified external device connects automatically. If the device’s transport cannot be identified or several devices are present, choose the capture source.\n\nAllow Camera access when your operating system asks. Audio input is selected separately in Settings.\n\nA connected card can be running without an HDMI picture. Protected HDCP content cannot be captured. Check the console and card instructions.");
        text->setWordWrap(true); text->setFixedWidth(430); layout->addWidget(text);
        auto *done = new QDialogButtonBox(QDialogButtonBox::Close); layout->addWidget(done); connect(done, &QDialogButtonBox::rejected, &dialog, &QDialog::accept); dialog.exec();
    }
    void showAbout() {
        QDialog dialog(this); dialog.setWindowTitle("About Console View");
        auto *layout = new QVBoxLayout(&dialog); layout->setContentsMargins(36, 30, 36, 30);
        auto *icon = new QLabel; icon->setPixmap(appPixmap(72)); icon->setAlignment(Qt::AlignCenter); layout->addWidget(icon);
        auto *text = new QLabel("<h2>Console View</h2><p>Version " + QApplication::applicationVersion() + "</p><p>Created by El Qorchi Ismail</p>"); text->setAlignment(Qt::AlignCenter); layout->addWidget(text);
        auto *links = new QHBoxLayout; links->addStretch();
        for (const auto &link : QList<QPair<QString, QString>>{{"github", "https://github.com/smailkorchi"}, {"instagram", "https://www.instagram.com/ismail.elqorchi/"}}) {
            auto *button = new QToolButton; button->setIcon(brandIcon(":/" + link.first + ".svg", palette().color(QPalette::WindowText))); button->setIconSize(QSize(22, 22));
            button->setToolTip(link.first == "github" ? "GitHub · smailkorchi" : "Instagram · ismail.elqorchi"); button->setAccessibleName(button->toolTip());
            connect(button, &QToolButton::clicked, &dialog, [link] { QDesktopServices::openUrl(QUrl(link.second)); }); links->addWidget(button);
        }
        links->addStretch(); layout->addLayout(links);
        auto *qtNotice = new QLabel("Qt 5.15 · LGPLv3\nDynamically linked Qt libraries may be replaced.");
        qtNotice->setAlignment(Qt::AlignCenter); qtNotice->setWordWrap(true); layout->addSpacing(18); layout->addWidget(qtNotice);
        dialog.exec();
    }
};

int main(int argc, char **argv) {
    QApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
    QApplication::setAttribute(Qt::AA_UseHighDpiPixmaps);
    QApplication app(argc, argv);
    QApplication::setApplicationName("Console View Compatibility");
    QApplication::setApplicationVersion(CONSOLE_VIEW_VERSION);
    QApplication::setOrganizationName("ElQorchiIsmail");
    const bool smoke = app.arguments().contains("--smoke-test");
    ConsoleWindow window(!smoke); window.show();
    if (smoke) {
        QTimer::singleShot(0, &app, [&app, &window] {
            QSvgRenderer github(QStringLiteral(":/github.svg")), instagram(QStringLiteral(":/instagram.svg"));
            const bool valid = !QPixmap(":/AppIcon.png").isNull() && github.isValid() && instagram.isValid() && !window.grab().isNull() && window.smokeCheck();
            std::cout << (valid ? "Console View Qt startup smoke passed\n" : "Console View Qt startup smoke failed\n");
            app.exit(valid ? 0 : 2);
        });
    }
    return app.exec();
}
