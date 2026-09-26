import SwiftUI

enum AnimationActivity {
    static let minimumInterval = 1.0 / 30
    static func isActive(scene: ScenePhase, reduceMotion: Bool, enabled: Bool = true) -> Bool {
        scene == .active && !reduceMotion && enabled
    }
}

/// Slow decoration does not need display-refresh cadence or inactive-window work.
struct ActiveAnimationTimeline<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: (Date) -> Content

    init(@ViewBuilder content: @escaping (Date) -> Content) { self.content = content }

    var body: some View {
        TimelineView(.animation(minimumInterval: AnimationActivity.minimumInterval, paused: !AnimationActivity.isActive(scene: scenePhase, reduceMotion: reduceMotion))) {
            content($0.date)
        }
    }
}

private struct ActiveRepeat: ViewModifier {
    let animation: Animation
    let enabled: Bool
    @Binding var value: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onAppear { sync() }
            .onChange(of: scenePhase) { _ in sync() }
            .onChange(of: reduceMotion) { _ in sync() }
            .onChange(of: enabled) { _ in sync() }
            .onDisappear { stop() }
    }

    private func sync() {
        guard AnimationActivity.isActive(scene: scenePhase, reduceMotion: reduceMotion, enabled: enabled) else { stop(); return }
        if !value { withAnimation(animation) { value = true } }
    }

    private func stop() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { value = false }
    }
}

extension View {
    func activeRepeating(_ animation: Animation, enabled: Bool = true, value: Binding<Bool>) -> some View {
        modifier(ActiveRepeat(animation: animation, enabled: enabled, value: value))
    }
}

struct ActivePulseRing: View {
    let tint: Color
    let duration: Double
    let delay: Double
    let startScale: CGFloat
    let endScale: CGFloat
    let startOpacity: Double
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(tint.opacity(0.35), lineWidth: 1.5)
            .scaleEffect(pulse ? endScale : startScale)
            .opacity(pulse ? 0 : startOpacity)
            .activeRepeating(.easeOut(duration: duration).repeatForever(autoreverses: false).delay(delay), value: $pulse)
    }
}
