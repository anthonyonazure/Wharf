//
//  WindowBehaviorStatus.swift
//  Wharf
//
//  Live state of the quit protection and quit on close services that the
//  Window Behavior pane shows: whether protection is actually running, and
//  which listed apps were last left open because a window was still there.
//  Nothing here is saved.
//

import Foundation
import Observation

@Observable
final class WindowBehaviorStatus {
    static let shared = WindowBehaviorStatus()

    /// Quit protection is switched on and allowed, but its key tap is not
    /// running (macOS turned it off and recreating it failed).
    var quitGuardInactive = false

    /// Listed apps whose last close did not quit them because a window was
    /// still present, keyed by lowercased bundle id, with the app name.
    var quitOnCloseSkipped: [String: String] = [:]

    private init() {}
}
