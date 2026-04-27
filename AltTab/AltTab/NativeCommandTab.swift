//
//  NativeCommandTab.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Uses SkyLight private API to disable macOS' native Command-Tab symbolic
//  hotkeys while AltTab is running. This is needed because the built-in app
//  switcher can otherwise handle Command-Tab before our event tap wins.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Foundation
import CoreGraphics

enum NativeCommandTab {
    private enum SymbolicHotKey: Int {
        case commandTab = 1
        case commandShiftTab = 2
    }

    static func setEnabled(_ enabled: Bool) {
        for hotKey in [SymbolicHotKey.commandTab, .commandShiftTab] {
            let error = CGSSetSymbolicHotKeyEnabled(hotKey.rawValue, enabled)
            if error != .success {
                NSLog("AltTab: Failed to set native hotkey %d enabled=%@ error=%d",
                      hotKey.rawValue, enabled.description, error.rawValue)
            }
        }
    }
}

/// Enables/disables symbolic hotkeys such as Command-Tab.
/// The setting persists after process exit, so callers must restore it.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
@discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int, _ isEnabled: Bool) -> CGError
