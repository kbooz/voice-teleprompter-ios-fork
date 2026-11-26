import SuflyorDomain
import SwiftUI
import UIKit

extension View {
    /// Keyboard and clicker keys while this view is on screen (UIKit presses): space, return, arrows, page up/down.
    /// Media keys and the camera buttons come through other paths (`AVCaptureEventInteraction`, the PiP window).
    public func hardwareKeys(enabled: Bool, onKey: @escaping (HardwareKey) -> Void) -> some View {
        hardwareKeys(enabled: enabled, handler: { key in
            onKey(key)
            return true
        })
    }

    /// Same, but `handler` says whether it used the key. An unused key goes on up the responder chain, so a system
    /// shortcut isn't swallowed because the prompter happens to be open.
    package func hardwareKeys(enabled: Bool, handler: @escaping (HardwareKey) -> Bool) -> some View {
        background(HardwareKeyCatcher(enabled: enabled, handler: handler).allowsHitTesting(false))
    }
}

/// Maps a USB/Bluetooth keyboard or presentation clicker key to the app's own key type.
enum HardwareKeyMapping {
    static func key(for usage: UIKeyboardHIDUsage) -> HardwareKey? {
        switch usage {
        case .keyboardSpacebar: .space
        case .keyboardReturnOrEnter, .keypadEnter: .enter
        case .keyboardUpArrow: .arrowUp
        case .keyboardDownArrow: .arrowDown
        case .keyboardLeftArrow: .arrowLeft
        case .keyboardRightArrow: .arrowRight
        case .keyboardPageUp: .pageUp
        case .keyboardPageDown: .pageDown
        default: nil
        }
    }
}

/// An invisible first responder: only the first responder receives `pressesBegan`, and SwiftUI has no press API of
/// its own for plain keyboards on iPhone.
private struct HardwareKeyCatcher: UIViewRepresentable {
    let enabled: Bool
    let handler: (HardwareKey) -> Bool

    func makeUIView(context: Context) -> KeyCatcherView {
        KeyCatcherView()
    }

    func updateUIView(_ view: KeyCatcherView, context: Context) {
        view.handler = handler
        view.setEnabled(enabled)
    }
}

@MainActor
private final class KeyCatcherView: UIView {
    var handler: ((HardwareKey) -> Bool)?
    private var enabled = false
    private var observers: [any NSObjectProtocol] = []

    override var canBecomeFirstResponder: Bool { enabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value { claimFocus() } else if isFirstResponder { resignFirstResponder() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        guard window != nil else { return }
        claimFocus()
        // A sheet or an alert takes the first responder away; take it back when it goes.
        for name in [UIApplication.didBecomeActiveNotification, UIWindow.didBecomeKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimFocus() }
            }
            observers.append(token)
        }
    }

    private func claimFocus() {
        guard enabled, window != nil, !isFirstResponder else { return }
        // Asking in the same layout pass can fail while the view is still being installed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unused = Set<UIPress>()
        for press in presses {
            if let usage = press.key?.keyCode, let key = HardwareKeyMapping.key(for: usage), handler?(key) == true {
                continue
            }
            unused.insert(press)
        }
        if !unused.isEmpty { super.pressesBegan(unused, with: event) }
    }

    // The matching release of a key we used must not reach other responders as a lone "ended".
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unused = presses.filter { press in
            guard let usage = press.key?.keyCode else { return true }
            return HardwareKeyMapping.key(for: usage) == nil
        }
        if !unused.isEmpty { super.pressesEnded(unused, with: event) }
    }
}
