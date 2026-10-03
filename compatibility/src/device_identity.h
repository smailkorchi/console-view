#pragma once
#include <QCameraInfo>
#include <QString>

enum class CameraTransport { Unknown, External, BuiltIn };
struct CameraIdentity {
    CameraTransport transport = CameraTransport::Unknown;
    QString stableId;
};
CameraIdentity identifyCamera(const QCameraInfo &camera);
bool cameraPermissionDenied();
QString cameraPrivacyUrl();
