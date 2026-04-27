//
//  PermissionManager.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Manages macOS permission requirements. Checks and prompts for Accessibility
//  access, polling only while the permission guide is waiting for a grant.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Cocoa
import ApplicationServices

final class PermissionManager {

    var onAccessibilityGranted: (() -> Void)?

    private var permissionTimer: Timer?
    private var permissionWindow: PermissionWindow?

    private let grantPollingInterval: TimeInterval = 0.5

    /// Checks Accessibility permission, prompting if needed, and polls until granted.
    func ensureAccessibility() {
        if AXIsProcessTrusted() {
            onAccessibilityGranted?()
            return
        }

        showPermissionWindow()
        startPolling()
    }

    private func showPermissionWindow() {
        if permissionWindow == nil {
            permissionWindow = PermissionWindow { [weak self] in
                self?.requestAccessibilityPrompt()
            }
        }
        permissionWindow?.updatePermissionStatus(isTrusted: false)
        permissionWindow?.show()
    }

    private func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Polls only while the permission guide is open, until Accessibility is granted.
    private func startPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: grantPollingInterval, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let isTrusted = AXIsProcessTrusted()
            self.permissionWindow?.updatePermissionStatus(isTrusted: isTrusted)
            guard isTrusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.permissionWindow?.updatePermissionStatus(isTrusted: true)
            self.permissionWindow?.closeAfterPermissionGranted()
            self.onAccessibilityGranted?()
        }
    }

}
