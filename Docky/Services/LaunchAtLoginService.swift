//
//  LaunchAtLoginService.swift
//  Docky
//

import Foundation
import ServiceManagement

final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notFound, .notRegistered:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }

            return true
        } catch {
            NSLog("[Wharf] Failed to update login item registration: \(error.localizedDescription)")
            return false
        }
    }

    private init() {}
}
