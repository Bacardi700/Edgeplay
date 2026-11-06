// SPDX-License-Identifier: AGPL-3.0-only

import GameController
import CoreHaptics

/// Reads any connected game controller (DualSense, DualShock 4, Xbox, Backbone, MFi)
/// and forwards it to the stream. Also drives rumble and the DualSense lightbar.
final class ControllerInput {
    var onPad: ((inout RPPadState) -> Void)?
    var onControllersChanged: ((Bool) -> Void)?
    /// Long-press PS/Home opens the in-stream menu instead of going to the console's home screen.
    var onMenuRequested: (() -> Void)?

    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?
    private var homeDownAt: TimeInterval?
    private var menuFiredForPress = false
    private var psPulseUntil: TimeInterval = 0
    private var pollTimer: Timer?

    var hasController: Bool { controller != nil }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        GCController.startWirelessControllerDiscovery {}
        pickController()
        // Poll as well as react to changes so held sticks keep flowing at a steady rate.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.send() }
    }

    func stop() {
        clearTriggers()
        pollTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        hapticEngine?.stop()
        controller?.extendedGamepad?.valueChangedHandler = nil
    }

    private func pickController() {
        let pad = GCController.controllers().first { $0.extendedGamepad != nil }
        controller = pad
        if let g = pad?.extendedGamepad {
            // Keep iOS from grabbing these buttons for screenshots/app switcher.
            g.buttonHome?.preferredSystemGestureState = .disabled
            g.buttonOptions?.preferredSystemGestureState = .disabled
            g.buttonMenu.preferredSystemGestureState = .disabled
            g.valueChangedHandler = { [weak self] _, _ in self?.send() }
        }
        setupHaptics()
        lastTriggers = (.off, .off)
        onControllersChanged?(pad != nil)
    }

    // MARK: input

    private func send() {
        guard let g = controller?.extendedGamepad else { return }
        var p = RPPadState()
        var b: UInt32 = 0
        func set(_ on: Bool, _ flag: Int) { if on { b |= UInt32(flag) } }

        set(g.buttonA.isPressed, RP_BTN_CROSS)
        set(g.buttonB.isPressed, RP_BTN_CIRCLE)
        set(g.buttonX.isPressed, RP_BTN_SQUARE)
        set(g.buttonY.isPressed, RP_BTN_TRIANGLE)
        set(g.dpad.left.isPressed, RP_BTN_LEFT)
        set(g.dpad.right.isPressed, RP_BTN_RIGHT)
        set(g.dpad.up.isPressed, RP_BTN_UP)
        set(g.dpad.down.isPressed, RP_BTN_DOWN)
        set(g.leftShoulder.isPressed, RP_BTN_L1)
        set(g.rightShoulder.isPressed, RP_BTN_R1)
        set(g.leftThumbstickButton?.isPressed ?? false, RP_BTN_L3)
        set(g.rightThumbstickButton?.isPressed ?? false, RP_BTN_R3)
        set(g.buttonMenu.isPressed, RP_BTN_OPTIONS)
        set(g.buttonOptions?.isPressed ?? false, RP_BTN_SHARE)

        // PS button: tap = PS button on the console, hold 1 s = EdgePlay menu.
        // The tap is forwarded on release so a long-press never reaches the console.
        let home = g.buttonHome?.isPressed ?? false
        let now = ProcessInfo.processInfo.systemUptime
        if home {
            if homeDownAt == nil { homeDownAt = now; menuFiredForPress = false }
            if !menuFiredForPress, let t = homeDownAt, now - t > 1.0 {
                menuFiredForPress = true
                onMenuRequested?()
            }
        } else if homeDownAt != nil {
            if !menuFiredForPress { psPulseUntil = now + 0.12 }
            homeDownAt = nil
        }
        if now < psPulseUntil { b |= UInt32(RP_BTN_PS) }

        p.l2 = UInt8(max(0, min(255, g.leftTrigger.value * 255)))
        p.r2 = UInt8(max(0, min(255, g.rightTrigger.value * 255)))
        p.left_x = axis(g.leftThumbstick.xAxis.value)
        p.left_y = axis(-g.leftThumbstick.yAxis.value)
        p.right_x = axis(g.rightThumbstick.xAxis.value)
        p.right_y = axis(-g.rightThumbstick.yAxis.value)

        if let ds = g as? GCDualSenseGamepad {
            set(ds.touchpadButton.isPressed, RP_BTN_TOUCHPAD)
            touch(ds.touchpadPrimary, slot: 0, into: &p)
            touch(ds.touchpadSecondary, slot: 1, into: &p)
        } else if let ds4 = g as? GCDualShockGamepad {
            set(ds4.touchpadButton.isPressed, RP_BTN_TOUCHPAD)
            touch(ds4.touchpadPrimary, slot: 0, into: &p)
            touch(ds4.touchpadSecondary, slot: 1, into: &p)
        }

        p.buttons = b
        onPad?(&p)
    }

    private func axis(_ v: Float) -> Int16 {
        Int16(max(-32767, min(32767, v * 32767)))
    }

    /// GameController reports touchpad fingers as -1...1 (y up) and 0,0 when lifted.
    private func touch(_ pad: GCControllerDirectionPad, slot: Int, into p: inout RPPadState) {
        let x = pad.xAxis.value, y = pad.yAxis.value
        let active = x != 0 || y != 0
        let tx = UInt16(max(0, min(1919, (x + 1) / 2 * 1919)))
        let ty = UInt16(max(0, min(941, (1 - (y + 1) / 2) * 941)))
        if slot == 0 {
            p.touch_active.0 = active; p.touch_x.0 = tx; p.touch_y.0 = ty
        } else {
            p.touch_active.1 = active; p.touch_x.1 = tx; p.touch_y.1 = ty
        }
    }

    // MARK: feedback

    private var lastTriggers: (TriggerEffect, TriggerEffect) = (.off, .off)

    /// Plays the console's adaptive trigger effects on a DualSense (no-op on other pads).
    func setTriggers(left: TriggerEffect, right: TriggerEffect, scale: Float) {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        if lastTriggers.0 != left { left.apply(to: ds.leftTrigger, scale: scale) }
        if lastTriggers.1 != right { right.apply(to: ds.rightTrigger, scale: scale) }
        lastTriggers = (left, right)
    }

    func clearTriggers() {
        guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        ds.leftTrigger.setModeOff()
        ds.rightTrigger.setModeOff()
        lastTriggers = (.off, .off)
    }

    func setLightbar(red: UInt8, green: UInt8, blue: UInt8) {
        controller?.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
    }

    private func setupHaptics() {
        hapticEngine?.stop()
        hapticEngine = nil
        hapticPlayer = nil
        guard let engine = controller?.haptics?.createEngine(withLocality: .default) else { return }
        engine.isAutoShutdownEnabled = false
        engine.resetHandler = { [weak engine] in try? engine?.start() }
        try? engine.start()
        hapticEngine = engine
    }

    func rumble(left: UInt8, right: UInt8) {
        guard let engine = hapticEngine else { return }
        let strength = Float(max(left, right)) / 255
        if strength <= 0.01 {
            try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            hapticPlayer = nil
            return
        }
        // Low-frequency motor -> lower sharpness.
        let sharpness: Float = right > left ? 0.6 : 0.2
        if let player = hapticPlayer {
            try? player.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.4, relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
            return
        }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
        ], relativeTime: 0, duration: 30)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        player.loopEnabled = true
        try? player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0)],
                                   atTime: CHHapticTimeImmediate)
        try? player.start(atTime: CHHapticTimeImmediate)
        hapticPlayer = player
    }
}
