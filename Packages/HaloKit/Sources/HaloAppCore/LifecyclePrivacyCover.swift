import HaloUI
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Opaque cover shown whenever `AppLock.isCovered` (locked, or not the active scene).
public struct LifecyclePrivacyCoverView: View {
    let lock: AppLock

    public init(lock: AppLock) {
        self.lock = lock
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.black)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                    .accessibilityHidden(true)
                Text("Halo is locked").font(.headline)
                if lock.isLocked {
                    Button("Unlock") { Task { await lock.unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(lock.isAuthenticating)
                }
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }
}

extension View {
    /// Covers the whole app while `lock.isCovered`, at the window level.
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
                if lock.isCovered { LifecyclePrivacyCoverView(lock: lock) }
            }
            #if os(iOS)
                .background {
                    LifecycleWindowSceneReader { scene in
                        controller.install(in: scene, lock: lock)
                    }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
                .onChange(of: lock.isCovered, initial: true) { _, covered in
                    controller.setCovered(covered)
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
        private var observers: [NSObjectProtocol] = []

        func install(in scene: UIWindowScene, lock: AppLock) {
            guard self.scene !== scene else { return }
            removeObservers()
            self.scene = scene

            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: LifecyclePrivacyCoverView(lock: lock))
            host.view.backgroundColor = .black
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            window.isHidden = !lock.isCovered
            self.window = window

            // Cover synchronously before the system snapshots the app for the switcher.
            let center = NotificationCenter.default
            for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
                observers.append(
                    center.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.setCovered(true) }
                    })
            }
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

        private func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        isolated deinit {
            removeObservers()
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
