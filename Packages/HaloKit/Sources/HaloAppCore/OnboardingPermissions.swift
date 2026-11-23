import AVFoundation
import Contacts
import Foundation
import Photos

/// Real system permission requester (AVCaptureDevice, PHPhotoLibrary, CNContactStore).
public struct SystemPermissionRequester: PermissionRequesting {
    public init() {}

    public func status(for permission: OnboardingPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .photos:
            return Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case .contacts:
            return Self.map(CNContactStore.authorizationStatus(for: .contacts))
        }
    }

    public func request(_ permission: OnboardingPermission) async -> PermissionStatus {
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .photos:
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        return await status(for: permission)
    }

    static func map(_ s: AVAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func map(_ s: PHAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: .granted
        case .limited: .limited
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func map(_ s: CNAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default:
            #if os(iOS)
                // `.limited` (iOS 18+) grants access to a user-selected subset of contacts.
                s == .limited ? .limited : .denied
            #else
                .denied
            #endif
        }
    }
}
