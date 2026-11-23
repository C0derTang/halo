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
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private var backgroundedAt: Date?

    public init(
        authenticator: any Authenticating,
        timeout: TimeInterval = AppLock.defaultTimeout,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.authenticator = authenticator
        self.timeout = timeout
        self.now = now
    }

    /// True when app content must not be visible: locked, or not the active scene (snapshot).
    public var isCovered: Bool { isLocked || phase != .active }

    public func scenePhaseChanged(to newPhase: ScenePhase) {
        phase = newPhase
        switch newPhase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = now() }
        case .active:
            if let at = backgroundedAt, now().timeIntervalSince(at) > timeout { isLocked = true }
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
        return ok
    }
}

/// Opaque privacy cover shown while the app is covered.
struct PrivacyCover: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
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
                if phase == .active, lock.isLocked { Task { await lock.unlock() } }
            }
    }
}
