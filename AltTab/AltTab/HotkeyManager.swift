//
//  HotkeyManager.swift
//  AltTab — Windows-style Window Switcher for macOS
//
//  Global hotkey detection via a CGEvent tap installed at the session level.
//  Implements a 2-state machine (idle/active) that tracks Command
//  key hold state and Tab/Arrow/Escape keypresses. The CGEvent callback is
//  a C function pointer bridged to Swift via Unmanaged<HotkeyManager>.
//  Tab keyDown/keyUp events are swallowed; flagsChanged is always passed through
//  to avoid breaking system modifier state. Includes retry logic with
//  exponential backoff for event tap creation, handling the case where the
//  Accessibility subsystem isn't ready at login time.
//
//  Author:  Sergio Farfan <sergio.farfan@gmail.com>
//  Version: 1.1.0
//  Date:    2026-03-17
//  License: MIT
//

import Cocoa
import Carbon.HIToolbox

// MARK: - Delegate Protocol

protocol HotkeyDelegate: AnyObject {
    func hotkeyDidActivate()
    func hotkeyDidCycleNext()
    func hotkeyDidCyclePrevious()
    func hotkeyDidConfirm()
    func hotkeyDidCancel()
    func hotkeyAccessibilityWasRevoked()
}

// MARK: - HotkeyManager

final class HotkeyManager {

    weak var delegate: HotkeyDelegate?

    private enum State {
        case idle
        case active
    }

    private var state: State = .idle
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowedTabKeyDown = false
    private var shouldRun = false

    // MARK: - Lifecycle

    /// Maximum number of retries for event tap creation at startup.
    private static let maxTapRetries = 10
    /// Delay between retries, in seconds (doubles each attempt, capped at 4s).
    private static let baseTapRetryInterval: TimeInterval = 0.5
    private var tapRetryCount = 0

    func start() {
        shouldRun = true
        guard eventTap == nil else { return }
        if !installEventTap() {
            scheduleRetry()
        }
    }

    /// Retry event tap creation with exponential back-off.
    /// At login the accessibility subsystem may not be ready yet.
    private func scheduleRetry() {
        guard shouldRun else { return }
        guard tapRetryCount < Self.maxTapRetries else {
            NSLog("AltTab: Gave up creating event tap after \(Self.maxTapRetries) retries.")
            return
        }
        let delay = min(Self.baseTapRetryInterval * pow(2.0, Double(tapRetryCount)), 4.0)
        tapRetryCount += 1
        NSLog("AltTab: Will retry event tap in %.1fs (attempt %d/%d)", delay, tapRetryCount, Self.maxTapRetries)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldRun, self.eventTap == nil else { return }
            if self.installEventTap() {
                NSLog("AltTab: Event tap created on retry %d", self.tapRetryCount)
            } else {
                self.scheduleRetry()
            }
        }
    }

    func stop() {
        shouldRun = false
        state = .idle
        swallowedTabKeyDown = false
        NativeCommandTab.setEnabled(true)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    // MARK: - Event Tap

    @discardableResult
    private func installEventTap() -> Bool {
        guard AXIsProcessTrusted() else {
            NativeCommandTab.setEnabled(true)
            NSLog("AltTab: Accessibility not trusted, refusing to install event tap.")
            return false
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) |
                                (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: userInfo
        ) else {
            NSLog("AltTab: Failed to create event tap. Is Accessibility enabled?")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NativeCommandTab.setEnabled(false)
        NSLog("AltTab: Created session event tap.")
        return true
    }

    // MARK: - Event Handling

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if shouldRun && !AXIsProcessTrusted() {
            NativeCommandTab.setEnabled(true)
            DispatchQueue.main.async { [weak self] in
                self?.stopAfterAccessibilityRevoked()
            }
            return Unmanaged.passUnretained(event)
        }

        // If tap is disabled, re-enable and force-cancel any active switcher
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            cancelActiveSwitcherIfNeeded()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if state == .active && !event.flags.contains(.maskCommand) {
            // Command released → confirm selection
            finishActive { $0.hotkeyDidConfirm() }
        }

        // NEVER swallow flagsChanged — always pass through
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        switch state {
        case .idle:
            // Command + Tab → activate switcher before macOS handles it.
            if keyCode == kVK_Tab && event.flags.contains(.maskCommand) {
                state = .active
                swallowedTabKeyDown = true
                notifyDelegate { $0.hotkeyDidActivate() }
                return nil // swallow the Tab
            }

        case .active:
            switch keyCode {
            case kVK_Tab:
                swallowedTabKeyDown = true
                if event.flags.contains(.maskShift) {
                    notifyDelegate { $0.hotkeyDidCyclePrevious() }
                } else {
                    notifyDelegate { $0.hotkeyDidCycleNext() }
                }
                return nil // swallow

            case kVK_LeftArrow:
                notifyDelegate { $0.hotkeyDidCyclePrevious() }
                return nil

            case kVK_RightArrow:
                notifyDelegate { $0.hotkeyDidCycleNext() }
                return nil

            case kVK_Escape:
                finishActive { $0.hotkeyDidCancel() }
                return nil

            case kVK_Return:
                finishActive { $0.hotkeyDidConfirm() }
                return nil

            default:
                break
            }
        }

        // Pass through all other keys
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard swallowedTabKeyDown else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Tab {
            swallowedTabKeyDown = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func cancelActiveSwitcherIfNeeded() {
        guard state == .active else { return }
        finishActive { $0.hotkeyDidCancel() }
    }

    private func stopAfterAccessibilityRevoked() {
        guard shouldRun else { return }
        NSLog("AltTab: Accessibility permission revoked, stopping event tap.")
        cancelActiveSwitcherIfNeeded()
        stop()
        notifyDelegate { $0.hotkeyAccessibilityWasRevoked() }
    }

    private func finishActive(_ action: @escaping (HotkeyDelegate) -> Void) {
        state = .idle
        swallowedTabKeyDown = false
        notifyDelegate(action)
    }

    private func notifyDelegate(_ action: @escaping (HotkeyDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            action(delegate)
        }
    }
}

// MARK: - C Callback Bridge

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type: type, event: event)
}
