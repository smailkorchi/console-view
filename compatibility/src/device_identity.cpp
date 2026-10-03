#include "device_identity.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#if defined(Q_OS_WIN)
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#endif
#if defined(Q_OS_MACOS)
extern "C" int cvCameraTransport(const char *identifier);
extern "C" bool cvCameraPermissionDenied();
#endif

static QString readText(const QString &path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()).trimmed() : QString();
}

CameraIdentity identifyCamera(const QCameraInfo &camera) {
    CameraIdentity identity;
    identity.stableId = camera.deviceName();
#if defined(Q_OS_MACOS)
    const int transport = cvCameraTransport(camera.deviceName().toUtf8().constData());
    identity.transport = transport == 1 ? CameraTransport::External : transport == 2 ? CameraTransport::BuiltIn : CameraTransport::Unknown;
#elif defined(Q_OS_LINUX)
    const QFileInfo video(camera.deviceName());
    if (!video.fileName().startsWith("video")) return identity;
    const QString target = video.canonicalFilePath();
    for (const QFileInfo &link : QDir("/dev/v4l/by-id").entryInfoList(QDir::Files | QDir::System)) {
        if (link.canonicalFilePath() == target) { identity.stableId = "v4l-id:" + link.fileName(); break; }
    }
    QDir device(QFileInfo("/sys/class/video4linux/" + video.fileName() + "/device").canonicalFilePath());
    if (device.path().isEmpty() || device.path() == ".") return identity;
    while (!device.isRoot()) {
        if (QFileInfo::exists(device.filePath("idVendor"))) {
            const QString removable = readText(device.filePath("removable"));
            identity.transport = removable == "removable" ? CameraTransport::External : removable == "fixed" ? CameraTransport::BuiltIn : CameraTransport::Unknown;
            if (!identity.stableId.startsWith("v4l-id:")) {
                const QString serial = readText(device.filePath("serial"));
                identity.stableId = serial.isEmpty() ? "usb-location:" + device.canonicalPath() : "usb:" + readText(device.filePath("idVendor")) + ":" + readText(device.filePath("idProduct")) + ":" + serial;
            }
            break;
        }
        if (!device.cdUp()) break;
    }
#elif defined(Q_OS_WIN)
    QString opaque = camera.deviceName().toLower();
    opaque.replace('#', '\\');
    HDEVINFO devices = SetupDiGetClassDevsW(nullptr, L"USB", nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) return identity;
    SP_DEVINFO_DATA data{};
    data.cbSize = sizeof(data);
    for (DWORD index = 0; SetupDiEnumDeviceInfo(devices, index, &data); ++index) {
        wchar_t identifier[MAX_DEVICE_ID_LEN]{};
        if (!SetupDiGetDeviceInstanceIdW(devices, &data, identifier, MAX_DEVICE_ID_LEN, nullptr)) continue;
        if (!opaque.contains(QString::fromWCharArray(identifier).toLower())) continue;
        DEVINST node = data.DevInst;
        for (int ancestor = 0; ancestor < 5; ++ancestor) {
            ULONG capabilities = 0, length = sizeof(capabilities);
            if (CM_Get_DevNode_Registry_PropertyW(node, CM_DRP_CAPABILITIES, nullptr, &capabilities, &length, 0) == CR_SUCCESS && (capabilities & CM_DEVCAP_REMOVABLE)) {
                identity.transport = CameraTransport::External;
                break;
            }
            DEVINST parent;
            if (CM_Get_Parent(&parent, node, 0) != CR_SUCCESS) break;
            node = parent;
        }
        break;
    }
    SetupDiDestroyDeviceInfoList(devices);
#endif
    return identity;
}

bool cameraPermissionDenied() {
#if defined(Q_OS_MACOS)
    return cvCameraPermissionDenied();
#else
    return false;
#endif
}
QString cameraPrivacyUrl() {
#if defined(Q_OS_MACOS)
    return "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera";
#elif defined(Q_OS_WIN)
    return "ms-settings:privacy-webcam";
#else
    return {};
#endif
}
