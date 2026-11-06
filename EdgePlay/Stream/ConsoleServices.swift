// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ConsoleState: Equatable {
    case unknown, checking, ready, resting, unreachable
}

/// Pings one address in the background and publishes the console's state.
/// Uses unicast, so it works on the LAN and over Tailscale without the
/// multicast entitlement iOS requires for broadcast discovery.
final class ConsoleProbe {
    private var handle: OpaquePointer?
    private let onChange: (ConsoleState, String?) -> Void
    private var timeout: DispatchWorkItem?
    private var lastState: ConsoleState = .checking

    /// `onChange` is called on the main thread with the state and the running game, if any.
    init(host: String, onChange: @escaping (ConsoleState, String?) -> Void) {
        self.onChange = onChange
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = host.withCString { h in
            rp_probe_start(h, 1500, { ctx, state, _, _, app in
                let me = Unmanaged<ConsoleProbe>.fromOpaque(ctx!).takeUnretainedValue()
                let s: ConsoleState
                switch state {
                case RP_HOST_READY: s = .ready
                case RP_HOST_STANDBY: s = .resting
                default: s = .unreachable
                }
                let appName = app.map { String(cString: $0) }
                DispatchQueue.main.async { me.report(s, appName) }
            }, ctx)
        }
        // No answer within a few seconds means unreachable.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lastState == .checking else { return }
            self.report(.unreachable, nil)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func report(_ s: ConsoleState, _ app: String?) {
        guard handle != nil else { return }
        lastState = s
        onChange(s, app)
    }

    func stop() {
        timeout?.cancel()
        if let h = handle {
            handle = nil
            // fini joins the ping thread; keep self alive until it is done.
            DispatchQueue.global().async { [self] in
                rp_probe_free(h)
                _ = self
            }
        }
    }

    deinit { if let h = handle { rp_probe_free(h) } }
}

/// One pairing attempt with a console.
final class Pairing {
    struct Result {
        var ps5: Bool
        var nickname: String
        var registKey: Data
        var morning: Data
        var mac: Data
    }

    private var handle: OpaquePointer?
    private let completion: (Result?, String?) -> Void

    /// `completion` runs on the main thread exactly once, with the result or chiaki's error message.
    init?(host: String, ps5: Bool, accountID: Data, pin: UInt32, completion: @escaping (Result?, String?) -> Void) {
        guard accountID.count == 8 else { return nil }
        self.completion = completion
        let ctx = Unmanaged.passRetained(self).toOpaque()   // released in the callback
        var id = [UInt8](accountID)
        let h = host.withCString { hostPtr in
            rp_regist_start(hostPtr, ps5, &id, pin, { ctx, ok, host, error in
                let me = Unmanaged<Pairing>.fromOpaque(ctx!).takeRetainedValue()
                var result: Result?
                if ok, let h = host?.pointee {
                    result = Result(ps5: h.ps5,
                                    nickname: stringFromTuple(h.nickname),
                                    registKey: dataFromTuple(h.regist_key),
                                    morning: dataFromTuple(h.morning),
                                    mac: dataFromTuple(h.mac))
                }
                let message = error.map { String(cString: $0) }
                DispatchQueue.main.async { me.completion(result, message) }
                // Free on another thread: rp_regist_free joins the thread we're on.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { me.free() }
            }, ctx)
        }
        guard let h else {
            Unmanaged<Pairing>.fromOpaque(ctx).release()
            return nil
        }
        handle = h
    }

    func cancel() {
        if let h = handle { rp_regist_cancel(h) }
    }

    private func free() {
        if let h = handle {
            handle = nil
            rp_regist_free(h)
        }
    }
}

enum Wake {
    /// Sends the wake-from-rest packet. Works over Tailscale too, as long as the
    /// console has "Enable Turning On PS5 from Network" switched on.
    @discardableResult
    static func send(to console: Console, host: String) -> Bool {
        var key = [UInt8](console.registKey)
        guard key.count == 16 else { return false }
        return host.withCString { rp_wakeup($0, &key, console.ps5) } == 0
    }
}
