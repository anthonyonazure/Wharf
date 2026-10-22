//
//  WindowSnapAction+Shortcuts.swift
//  Wharf
//
//  Default global shortcuts for window snapping. Kept apart from
//  WindowSnapGeometry.swift because KeyboardShortcut needs AppKit.
//
//  Defaults follow Vorssaint (vorssaint/vorssaint-utils, GPL-3.0) for the
//  halves, maximize and display moves. Center and Restore avoid Vorssaint's
//  Control-Option-C and Control-Option-R: Windows Keyboard Mode rewrites
//  Control plus C or R into Command, so those would never reach the hot key.
//

import AppKit
import Carbon.HIToolbox

extension WindowSnapAction {
    /// Only the most common actions claim a system-wide combination by
    /// default; the rest start unset so enabling snapping never takes keys
    /// the user did not ask for.
    var defaultShortcut: KeyboardShortcut? {
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
        let ctrlOptCmd: NSEvent.ModifierFlags = [.control, .option, .command]
        switch self {
        case .leftHalf: return KeyboardShortcut(keyCode: UInt16(kVK_LeftArrow), modifierFlags: ctrlOpt)
        case .rightHalf: return KeyboardShortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: ctrlOpt)
        case .topHalf: return KeyboardShortcut(keyCode: UInt16(kVK_UpArrow), modifierFlags: ctrlOpt)
        case .bottomHalf: return KeyboardShortcut(keyCode: UInt16(kVK_DownArrow), modifierFlags: ctrlOpt)
        case .maximize: return KeyboardShortcut(keyCode: UInt16(kVK_Return), modifierFlags: ctrlOpt)
        case .center: return KeyboardShortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: ctrlOpt)
        case .restore: return KeyboardShortcut(keyCode: UInt16(kVK_Delete), modifierFlags: ctrlOpt)
        case .nextDisplay: return KeyboardShortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: ctrlOptCmd)
        case .previousDisplay: return KeyboardShortcut(keyCode: UInt16(kVK_LeftArrow), modifierFlags: ctrlOptCmd)
        default: return nil
        }
    }
}
