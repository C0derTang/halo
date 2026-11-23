import HaloUI
import SwiftUI

#if os(iOS)
    import UIKit
#endif

extension View {
    /// Covers the whole app with HaloUI's `PrivacyCover` while `lock.isCovered`, at the window level.
    ///
    /// On iOS the cover is a separate `UIWindow` above `.alert`, so sheets, confirmation dialogs and
    /// alerts presented by the app are covered too (an overlay on the root view would sit *below*
    /// them). It is shown synchronously on `willDeactivate` / `didEnterBackground`, before the
    /// app-switcher snapshot is taken. The content itself is also blurred, hidden from
    /// accessibility and made non-interactive, which covers the first frame before the window
    /// exists and the macOS host.
    ///
    /// Scene-phase *logic* (AppLock rules, auto-prompt) lives in `AppEnvironment.scenePhaseChanged`;
    /// this modifier only renders.
    public func lifecyclePrivacyCover(_ lock: AppLock) -> some View {
        modifier(LifecyclePrivacyCoverModifier(lock: lock))
    }
}

struct LifecyclePrivacyCoverModifier: ViewModifier {
    let lock: AppLock

    #if os(iOS)
        @State private var controller = LifecyclePrivacyWindowController()
    #endif

    func body(content: Content) -> some View {
        content
            .blur(radius: lock.isCovered ? 30 : 0)
            .allowsHitTesting(!lock.isCovered)
            .accessibilityHidden(lock.isCovered)
            .overlay {
                if lock.isCovered { PrivacyCover(lock: lock) }
            }
            #if os(iOS)
                .background {
                    LifecycleWindowSceneReader { scene in
                        controller.install(in: scene, lock: lock)
                    }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
                .onChange(of: lock.isCovered, initial: true) { _, _ in
                    controller.syncWithLock()
                }
            #endif
    }
}

#if os(iOS)
    /// Owns the cover window for one scene.
    @MainActor
    final class LifecyclePrivacyWindowController {
        private var window: UIWindow?
        private weak var scene: UIWindowScene?
        private weak var lock: AppLock?
        private var observers = NotificationObservers()

        func install(in scene: UIWindowScene, lock: AppLock) {
            guard self.scene !== scene else { return }
            observers = NotificationObservers()
            self.scene = scene
            self.lock = lock

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: PrivacyCover(lock: lock))
            host.view.backgroundColor = .black
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            window.isHidden = !lock.isCovered
            self.window = window

            // Cover synchronously before the system snapshots the app for the switcher.
            for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
                observers.add(name, object: scene) { [weak self] in self?.setCovered(true) }
            }
            // On activation re-sync with the lock, so a cover shown by the notifications above can
            // never stay up after `isCovered` went false (the SwiftUI onChange may not fire again).
            observers.add(UIScene.didActivateNotification, object: scene) { [weak self] in
                self?.syncWithLock()
            }
        }

        func syncWithLock() {
            guard let lock else { return }
            setCovered(lock.isCovered)
        }

        func setCovered(_ covered: Bool) {
            guard let window else { return }
            if covered, window.isHidden {
                // Dismiss the keyboard so nothing typed (e.g. in the erase sheet) peeks above the cover.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            window.isHidden = !covered
        }
    }

    /// NotificationCenter registrations removed when the holder goes away. Non-isolated `deinit`
    /// (no `isolated deinit` needed): it only touches its own tokens.
    final class NotificationObservers {
        private var tokens: [NSObjectProtocol] = []

        @MainActor
        func add(
            _ name: Notification.Name, object: AnyObject, _ handler: @escaping @MainActor @Sendable () -> Void
        ) {
            tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                })
        }

        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// Reports the `UIWindowScene` hosting this view once it is in a window.
    struct LifecycleWindowSceneReader: UIViewRepresentable {
        let onScene: @MainActor (UIWindowScene) -> Void

        func makeUIView(context: Context) -> SceneReaderView {
            let view = SceneReaderView()
            view.onScene = onScene
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ view: SceneReaderView, context: Context) {
            view.onScene = onScene
            view.report()
        }

        final class SceneReaderView: UIView {
            var onScene: (@MainActor (UIWindowScene) -> Void)?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                report()
            }

            func report() {
                if let scene = window?.windowScene { onScene?(scene) }
            }
        }
    }
#endif
