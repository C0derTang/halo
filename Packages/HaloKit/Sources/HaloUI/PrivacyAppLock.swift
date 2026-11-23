import Observation
import SwiftUI

/// App lock. Locked on launch and after the app spent longer than `timeout` in the background.
/// While locked, or whenever the scene is not active (app switcher snapshot), content is covered.
@Observable @MainActor
public final class AppLock {
    public static let defaultTimeout: TimeInterval = 30

    public private(set) var isLocked = true
    public private(set) var phase: ScenePhase = .active
    public private(set) var isAuthenticating = false

    @ObservationIgnored private let authenticator: any Authenticating
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private var backgroundedAt: TimeInterval?
    /// Set when the last prompt failed or was cancelled; suppresses automatic re-prompting.
    public private(set) var needsManualUnlock = false

    /// Monotonic seconds (includes sleep, unaffected by wall-clock changes).
    public static let monotonicNow: @MainActor () -> TimeInterval = {
        let clock = ContinuousClock()
        let start = clock.now
        return {
            let d = start.duration(to: clock.now).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
    }()

    public init(
        authenticator: any Authenticating,
        timeout: TimeInterval = AppLock.defaultTimeout,
        now: @escaping @MainActor () -> TimeInterval = AppLock.monotonicNow
    ) {
        self.authenticator = authenticator
        self.timeout = timeout
        self.now = now
    }

    /// True when app content must not be visible: locked, or not the active scene (snapshot).
    public var isCovered: Bool { isLocked || phase != .active }

    /// Whether becoming active should automatically prompt. False after a failed/cancelled prompt:
    /// the user must tap Unlock, so cancelling never causes a re-prompt loop.
    public var shouldAutoPrompt: Bool { isLocked && !needsManualUnlock }

    public func scenePhaseChanged(to newPhase: ScenePhase) {
        phase = newPhase
        switch newPhase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = now() }
        case .active:
            if let at = backgroundedAt, now() - at > timeout {
                isLocked = true
                needsManualUnlock = false
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    /// Prompts for authentication. Stays locked on failure.
    @discardableResult
    public func unlock() async -> Bool {
        guard isLocked else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let ok = await authenticator.authenticate(reason: "Unlock Halo")
        if ok { isLocked = false }
        needsManualUnlock = !ok
        return ok
    }
}

/// Opaque privacy cover shown while the app is covered. The app shows it at the window level
/// (above sheets and alerts); `privacyLock(_:)` shows it over a single view.
public struct PrivacyCover: View {
    let lock: AppLock

    public init(lock: AppLock) {
        self.lock = lock
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.black)
            Rectangle().fill(.ultraThinMaterial)
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
    /// Hides the wrapped content behind a privacy cover whenever `lock.isCovered`.
    public func privacyLock(_ lock: AppLock) -> some View {
        modifier(PrivacyLockModifier(lock: lock))
    }
}

struct PrivacyLockModifier: ViewModifier {
    let lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .blur(radius: lock.isCovered ? 30 : 0)
            .allowsHitTesting(!lock.isCovered)
            .accessibilityHidden(lock.isCovered)
            .overlay { if lock.isCovered { PrivacyCover(lock: lock) } }
            .onChange(of: scenePhase, initial: true) { _, phase in
                lock.scenePhaseChanged(to: phase)
                if phase == .active, lock.shouldAutoPrompt { Task { await lock.unlock() } }
            }
    }
}
