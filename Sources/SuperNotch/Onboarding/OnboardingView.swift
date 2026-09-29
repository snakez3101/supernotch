// Owner: notch-shell (SPEC §A.11, §D.10).
//
// First-launch wizard (also "Run Setup Again" in Settings › General). A single-window pager with Back/Next:
//   1. Welcome (shell) · 2. Claude Code hooks (claude-app) · 3. Spotify (media) · 4. Clipboard paste
//   (shelf-clipboard) · 5. Done (shell).
// Every step can be skipped with Next; the wizard never blocks the app. Finish sets `onboardingCompleted`, and
// AppDelegate closes the window. Hosted in a normal window (light or dark), so only semantic colours are used.
import SuperNotchCore
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case hooks
    case spotify
    case paste
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .hooks: return "Claude Code"
        case .spotify: return "Spotify"
        case .paste: return "Clipboard"
        case .done: return "Done"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settingsStore

    @State private var step: OnboardingStep = .welcome
    @State private var movesForward = true

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                OnboardingStepContent(step: step)
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .clipped()

            Divider()

            HStack(spacing: 10) {
                OnboardingProgressDots(current: step)
                Spacer()
                if let previous = step.previous {
                    Button("Back") {
                        go(to: previous)
                    }
                }
                if let next = step.next {
                    Button(step == .welcome ? "Get Started" : "Next") {
                        go(to: next)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") {
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(to target: OnboardingStep) {
        movesForward = target.rawValue > step.rawValue
        withAnimation(.easeInOut(duration: 0.25)) {
            step = target
        }
    }

    private func finish() {
        Log.app.info("Onboarding finished")
        settingsStore.settings.onboardingCompleted = true
    }
}

/// The page for one step. Stream steps are hosted as-is.
private struct OnboardingStepContent: View {
    let step: OnboardingStep

    var body: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep()
        case .hooks:
            OnboardingHooksStep()
        case .spotify:
            OnboardingSpotifyStep()
        case .paste:
            OnboardingPasteStep()
        case .done:
            OnboardingDoneStep()
        }
    }
}

private struct OnboardingProgressDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count): \(current.title)")
    }
}
