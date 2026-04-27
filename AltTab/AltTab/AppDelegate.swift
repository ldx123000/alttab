//
//  AppDelegate.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Application lifecycle and orchestration. Sets up the menu bar status item,
//  manages permissions, and coordinates the hotkey manager, window model,
//  and switcher panel. Implements HotkeyDelegate to respond to Command-Tab
//  state machine transitions.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, HotkeyDelegate {

    private enum SwitcherState {
        case inactive
        case pendingReveal
        case visible
    }

    private var statusItem: NSStatusItem!
    private var preferencesMenu: PreferencesMenu!
    private var hotkeyManager: HotkeyManager!
    private var windowModel: WindowModel?
    private var switcherPanel: SwitcherPanel!
    private var permissionManager: PermissionManager!

    private var currentWindows: [WindowInfo] = []
    private var selectedIndex: Int = 0
    private var switcherState: SwitcherState = .inactive
    private var revealSwitcherWorkItem: DispatchWorkItem?

    private let switcherRevealDelay: TimeInterval = 0.18

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("AltTab: applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        permissionManager = PermissionManager()
        permissionManager.onAccessibilityGranted = { [weak self] in
            self?.startHotkeyWhenPermissionsAreReady()
        }

        switcherPanel = SwitcherPanel()

        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // At login the TCC daemon may not be ready yet, causing a false negative.
        // Wait briefly before prompting for permissions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startHotkeyWhenPermissionsAreReady()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeCommandTab.setEnabled(true)
    }

    private func startHotkeyWhenPermissionsAreReady() {
        guard AXIsProcessTrusted() else {
            NSLog("AltTab: Accessibility not trusted, prompting user")
            permissionManager.ensureAccessibility()
            return
        }

        if windowModel == nil {
            windowModel = WindowModel()
        }
        hotkeyManager.start()
        NSLog("AltTab: Permissions granted, hotkey active")
    }

    private func handleAccessibilityRevoked() {
        NSLog("AltTab: Accessibility permission revoked, disabling hotkeys")
        dismissSwitcher()
        currentWindows.removeAll()
        hotkeyManager.stop()
        windowModel = nil
        NativeCommandTab.setEnabled(true)
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                  accessibilityDescription: "AltTab") {
                img.isTemplate = true
                button.image = img
            } else {
                // Fallback if SF Symbol unavailable
                button.title = "⌘⇥"
            }
        }
        preferencesMenu = PreferencesMenu()
        statusItem.menu = preferencesMenu.menu
        NSLog("AltTab: Status item installed")
    }

    // MARK: - HotkeyDelegate

    func hotkeyDidActivate() {
        guard let windowModel = windowModel else { return }
        currentWindows = windowModel.enumerateWindows()
        guard !currentWindows.isEmpty else { return }
        selectedIndex = min(1, currentWindows.count - 1) // start on second window (MRU)
        switcherState = .pendingReveal

        revealSwitcherWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showSwitcherPanel()
        }
        revealSwitcherWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + switcherRevealDelay, execute: workItem)
    }

    func hotkeyDidCycleNext() {
        guard !currentWindows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % currentWindows.count
        updateOrRevealSwitcher()
    }

    func hotkeyDidCyclePrevious() {
        guard !currentWindows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + currentWindows.count) % currentWindows.count
        updateOrRevealSwitcher()
    }

    func hotkeyDidConfirm() {
        guard switcherState != .inactive, !currentWindows.isEmpty,
              selectedIndex < currentWindows.count else {
            dismissSwitcher()
            return
        }
        let window = currentWindows[selectedIndex]
        dismissSwitcher()
        WindowActivator.activate(window: window)
        windowModel?.promoteToFront(windowID: window.windowID)
    }

    func hotkeyDidCancel() {
        dismissSwitcher()
    }

    func hotkeyAccessibilityWasRevoked() {
        handleAccessibilityRevoked()
        permissionManager.ensureAccessibility()
    }

    private func dismissSwitcher() {
        revealSwitcherWorkItem?.cancel()
        revealSwitcherWorkItem = nil
        switcherState = .inactive
        switcherPanel.dismiss()
    }

    private func updateOrRevealSwitcher() {
        switch switcherState {
        case .visible:
            switcherPanel.updateSelection(index: selectedIndex)
        case .pendingReveal:
            showSwitcherPanel()
        case .inactive:
            break
        }
    }

    private func showSwitcherPanel() {
        guard switcherState == .pendingReveal, !currentWindows.isEmpty else { return }
        revealSwitcherWorkItem?.cancel()
        revealSwitcherWorkItem = nil
        switcherState = .visible
        switcherPanel.show(windows: currentWindows, selectedIndex: selectedIndex)
    }
}
