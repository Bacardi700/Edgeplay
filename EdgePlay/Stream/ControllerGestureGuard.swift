// SPDX-License-Identifier: AGPL-3.0-only

import GameController
import UIKit

/// Stops iOS from grabbing the controller's PS / Home, Create and Options buttons
/// (App Library, Games app, Game Center, screenshots) while EdgePlay is open, so
/// they reach the console instead.
///
/// Apple's documented way is to disable the system gesture on the element from the
/// controller's physical input profile. iOS can reset this when a controller
/// reconnects or becomes current, so it's re-applied on every such event.
final class ControllerGestureGuard {
    static let shared = ControllerGestureGuard()
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidBecomeCurrent] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if let c = note.object as? GCController { self?.apply(to: c) }
            })
        }
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyAll()
        })
        applyAll()
    }

    func applyAll() {
        GCController.controllers().forEach(apply)
    }

    func apply(to controller: GCController) {
        let profile = controller.physicalInputProfile
        for name in [GCInputButtonHome, GCInputButtonOptions, GCInputButtonMenu, GCInputButtonShare] {
            profile.buttons[name]?.preferredSystemGestureState = .disabled
        }
        if let g = controller.extendedGamepad {
            g.buttonHome?.preferredSystemGestureState = .disabled
            g.buttonOptions?.preferredSystemGestureState = .disabled
            g.buttonMenu.preferredSystemGestureState = .disabled
        }
    }
}
