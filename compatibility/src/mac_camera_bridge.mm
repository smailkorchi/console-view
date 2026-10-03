#import <AVFoundation/AVFoundation.h>
#import <IOKit/audio/IOAudioTypes.h>

extern "C" int cvCameraTransport(const char *identifier) {
    @autoreleasepool {
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:[NSString stringWithUTF8String:identifier]];
        if (!device) return 0;
        if (device.transportType == kIOAudioDeviceTransportTypeBuiltIn) return 2;
        if (device.position == AVCaptureDevicePositionFront) return 2;
        if (device.transportType == kIOAudioDeviceTransportTypeUSB || device.transportType == kIOAudioDeviceTransportTypeFireWire) return 1;
        return 0;
    }
}
extern "C" bool cvCameraPermissionDenied() {
    @autoreleasepool {
        if (@available(macOS 10.14, *)) {
            const AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
            return status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted;
        }
        return false;
    }
}
