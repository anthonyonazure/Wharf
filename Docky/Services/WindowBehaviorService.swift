//
//  WindowBehaviorService.swift
//  Wharf
//
//  Starts the three Window Behavior features. Each one watches its own
//  switch and the Accessibility grant, and does nothing while either is off.
//

import Foundation

enum WindowBehaviorService {
    static func start() {
        GreenButtonMaximizeService.shared.start()
        QuitOnCloseService.shared.start()
        QuitGuardService.shared.start()
    }
}
