import SwiftUI
import UIKit

/// App-wide "is the keyboard up" flag. Animation surfaces (StudioCardCanvas,
/// PatternStripView, BeatPanelView's bar meter, LookPreview) read it alongside
/// `\.isTabActive` so typing never competes with live canvases for frame time.
///
/// Driven by UIResponder keyboard notifications — `willShow` flips it *before*
/// the rise animation (the jank window) and `didHide` clears it only once the
/// keyboard is fully gone — so no per-TextField wiring exists to forget.
@MainActor
@Observable
final class KeyboardState {
    static let shared = KeyboardState()

    private(set) var isKeyboardUp = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        // UIKit posts keyboard notifications on the main thread; queue nil keeps
        // delivery synchronous there (KeyboardStateTests relies on that).
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isKeyboardUp = true }
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isKeyboardUp = false }
        })
    }
}
