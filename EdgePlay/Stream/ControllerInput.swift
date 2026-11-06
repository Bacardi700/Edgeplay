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
    private var homeDownAt: TimeInterval?
    private var menuFiredForPress = false
    private var psPulseUntil: TimeInterval = 0
    private var pollTimer: Timer?

    var hasController: Bool { controller != nil }

    // Motion
    var motionEnabled = true { didSet { updateMotionActivation() } }
    var invertHorizontal = false
    var invertVertical = false
    // Rumble
    var phoneVibration = true
    private var lastRumbleAt: TimeInterval = 0

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        GCController.startWirelessControllerDiscovery {}
        pickController()
        // Poll as well as react to changes so held sticks keep flowing at a steady rate.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.send(); self?.decayRumble() }
    }

    private func updateMotionActivation() {
        guard let m = controller?.motion else { return }
        if m.sensorsRequireManualActivation { m.sensorsActive = motionEnabled }
        if motionEnabled {
            m.valueChangedHandler = { [weak self] _ in self?.send() }
        } else {
            m.valueChangedHandler = nil
        }
    }

    /// GameController reports motion as +X right, +Y forward (away from you), +Z up out of
    /// the face, with gravity pointing down. The console expects the DualSense/SDL frame:
    /// +X right, +Y up, +Z toward you, and accelerometer reading +1 g up at rest.
    private func fillMotion(_ p: inout RPPadState) {
        guard motionEnabled, let m = controller?.motion, m.hasRotationRate else { return }
        let r = m.rotationRate
        var a: GCAcceleration
        if m.hasGravityAndUserAcceleration {
            a = GCAcceleration(x: m.gravity.x + m.userAcceleration.x,
                               y: m.gravity.y + m.userAcceleration.y,
                               z: m.gravity.z + m.userAcceleration.z)
        } else {
            a = m.acceleration
        }
        p.has_motion = true
        p.gyro_x = Float(r.x) * (invertVertical ? -1 : 1)          // pitch
        p.gyro_y = Float(r.z) * (invertHorizontal ? -1 : 1)        // yaw
        p.gyro_z = Float(-r.y)                                     // roll
        p.accel_x = Float(-a.x)
        p.accel_y = Float(-a.z)
        p.accel_z = Float(a.y)
        p.motion_timestamp_us = UInt32(truncatingIfNeeded: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000))
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
        if let pad { ControllerGestureGuard.shared.apply(to: pad) }
        if let g = pad?.extendedGamepad {
            g.valueChangedHandler = { [weak self] _, _ in self?.send() }
        }
        updateMotionActivation()
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
        // If iOS keeps the real PS button for itself (Games app / Game Center), pressing
        // Create + Options together does the same job: tap = PS, hold = menu.
        let createOptions = (g.buttonOptions?.isPressed ?? false) && g.buttonMenu.isPressed
        if createOptions {
            b &= ~(UInt32(RP_BTN_OPTIONS) | UInt32(RP_BTN_SHARE))
        }
        let home = (g.buttonHome?.isPressed ?? false) || createOptions
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
        fillMotion(&p)
        onPad?(&p)
    }

    /// Stops rumbling once the console stops sending haptics.
    private func decayRumble() {
        if sidePlayers.contains(where: { $0 != nil }), ProcessInfo.processInfo.systemUptime - lastRumbleAt > 0.15 {
            for i in sidePlayers.indices {
                try? sidePlayers[i]?.stop(atTime: CHHapticTimeImmediate)
                sidePlayers[i] = nil
            }
        }
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
        sideEngines?.0.stop()
        sideEngines?.1.stop()
        sideEngines = nil
        sidePlayers = [nil, nil]
        let engine: CHHapticEngine?
        if let pad = controller?.haptics?.createEngine(withLocality: .default) {
            engine = pad
        } else if phoneVibration, CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            // No motors in the controller (or no controller): use the iPhone's Taptic Engine.
            engine = try? CHHapticEngine()
        } else {
            engine = nil
        }
        guard let engine else { return }
        engine.isAutoShutdownEnabled = false
        engine.playsHapticsOnly = true
        engine.resetHandler = { [weak self, weak engine] in
            self?.engineRunning = (try? engine?.start()) != nil
        }
        engine.stoppedHandler = { [weak self] _ in self?.engineRunning = false }
        engineRunning = (try? engine.start()) != nil
        hapticEngine = engine

        sideEngines = nil
        if let h = controller?.haptics,
           h.supportedLocalities.contains(.leftHandle), h.supportedLocalities.contains(.rightHandle),
           let le = h.createEngine(withLocality: .leftHandle),
           let re = h.createEngine(withLocality: .rightHandle) {
            for e in [le, re] {
                e.isAutoShutdownEnabled = false
                e.playsHapticsOnly = true
                e.resetHandler = { [weak e] in try? e?.start() }
                try? e.start()
            }
            sideEngines = (le, re)
        }
    }

    /// Last rumble strengths received from the console (0-255), for the stats overlay.
    private(set) var lastRumble: (UInt8, UInt8) = (0, 0)
    private var engineRunning = false
    /// Separate engines for the left and right grip when the controller supports it,
    /// so a hit on the left is felt on the left.
    private var sideEngines: (CHHapticEngine, CHHapticEngine)?
    private var sidePlayers: [CHHapticPatternPlayer?] = [nil, nil]

    /// Plays rumble as short overlapping pulses. Simple continuous events are supported by
    /// every controller haptics engine on iOS (dynamic parameter control isn't always).
    func rumble(left: UInt8, right: UInt8, sharpLeft: Float? = nil, sharpRight: Float? = nil, strength scale: Float = 0.7) {
        lastRumble = (left, right)
        if hapticEngine == nil || !engineRunning { setupHaptics() }
        lastRumbleAt = ProcessInfo.processInfo.systemUptime
        let k = max(0.1, min(scale, 1))

        if let engines = sideEngines {
            let (le, re) = engines
            // HD haptics channels are the two sides of the controller.
            pulse(on: le, slot: 0, strength: Float(left) / 255 * k, sharpness: sharpLeft ?? 0.45)
            pulse(on: re, slot: 1, strength: Float(right) / 255 * k, sharpness: sharpRight ?? 0.45)
            return
        }
        guard let engine = hapticEngine else { return }
        let s = Float(max(left, right)) / 255 * k
        let sharp = max(sharpLeft ?? 0.45, sharpRight ?? 0.45)
        pulse(on: engine, slot: 0, strength: s, sharpness: sharp)
    }

    private func pulse(on engine: CHHapticEngine, slot: Int, strength: Float, sharpness: Float) {
        if strength <= 0.02 {
            try? sidePlayers[slot]?.stop(atTime: CHHapticTimeImmediate)
            sidePlayers[slot] = nil
            return
        }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, strength)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness))),
        ], relativeTime: 0, duration: 0.12)
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try? sidePlayers[slot]?.stop(atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
            sidePlayers[slot] = player
        } catch {
            engineRunning = false   // engine was stopped (e.g. backgrounded); rebuild next time
        }
    }

    /// Plays a half-second buzz on the connected controller (or the iPhone). Returns a short
    /// description of what happened, for the Settings test button.
    static func testVibration() -> String {
        guard let controller = GCController.current ?? GCController.controllers().first else {
            return "No controller connected."
        }
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else {
            return "\(controller.vendorName ?? "This controller") doesn't offer vibration to apps on iOS."
        }
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ], relativeTime: 0, duration: 0.5)
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { engine.stop() }
            return "Sent a vibration to \(controller.vendorName ?? "the controller")."
        } catch {
            return "Vibration failed: \(error.localizedDescription)"
        }
    }
}
