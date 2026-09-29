// Owner: media stream. Small building blocks shared by the media views (all internal to the Media folder).
import AppKit
import SuperNotchCore
import SwiftUI

extension MediaAccentColor {
    /// SwiftUI colour for tints.
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

// MARK: - Artwork

/// Rounded, square cover with a quiet placeholder while there is none.
struct MediaArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(DesignTokens.Colors.controlFill)
                Image(systemName: "music.note")
                    .font(.system(size: max(8, size * 0.4), weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Marquee

/// One line of text: shown in full when it fits, gently scrolling back and forth when it does not.
/// The scroll is a single `repeatForever` animation (driven by the render server), not a per-frame timer, and it
/// only exists while the text overflows and the view is on screen.
struct MediaMarqueeText: View {
    let text: String
    let font: Font
    let height: CGFloat

    /// Scroll speed in points per second.
    private let speed: CGFloat = 24

    @State private var textWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    init(text: String, font: Font, height: CGFloat) {
        self.text = text
        self.font = font
        self.height = height
    }

    private var overflow: CGFloat { max(0, textWidth - viewportWidth) }

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { textWidth = $0 })
                .offset(x: offset)
                .frame(width: proxy.size.width, alignment: .leading)
                .onChange(of: proxy.size.width, initial: true) { _, newWidth in viewportWidth = newWidth }
        }
        .frame(height: height)
        .clipped()
        .task(id: "\(text)|\(Int(overflow.rounded()))") { await runMarquee() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func runMarquee() async {
        withAnimation(.linear(duration: 0.01)) { offset = 0 }
        let distance = overflow
        guard distance > 2 else { return }
        try? await Task.sleep(for: .seconds(1.4))
        guard !Task.isCancelled else { return }
        let duration = max(1.2, Double(distance / speed))
        withAnimation(.easeInOut(duration: duration).delay(0.8).repeatForever(autoreverses: true)) {
            offset = -distance
        }
    }
}

// MARK: - Transport button

struct MediaTransportButton: View {
    let symbol: String
    let label: String
    let font: Font
    let width: CGFloat
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .frame(width: width, height: 22)
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Scrubber

/// "1:02 ━━━●───── -2:33". The bar is driven by extrapolation (`PlaybackSnapshot.position(at:)`), refreshed by a
/// `TimelineView` at 2 Hz that is paused while Spotify is paused or the user drags; the bar is 3 pt tall, 6 pt
/// while hovered or dragged. Dragging (or a click) seeks on release and holds the notch open meanwhile.
struct MediaScrubber: View {
    @Environment(NotchViewModel.self) private var notch

    let snapshot: PlaybackSnapshot
    let tint: Color
    let isEnabled: Bool
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var isHovering = false
    @State private var holdToken: NotchHoldToken?

    init(snapshot: PlaybackSnapshot, tint: Color, isEnabled: Bool, onSeek: @escaping (Double) -> Void) {
        self.snapshot = snapshot
        self.tint = tint
        self.isEnabled = isEnabled
        self.onSeek = onSeek
    }

    private var duration: Double { snapshot.track?.durationSeconds ?? 0 }
    private var barHeight: CGFloat { isEnabled && (isHovering || dragFraction != nil) ? 6 : 3 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !snapshot.isPlaying || dragFraction != nil)) { context in
            let position = displayedPosition(at: context.date)
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(PlaybackSnapshot.formatTime(position))
                    .frame(minWidth: 26, alignment: .leading)
                    .fixedSize()
                bar(fraction: duration > 0 ? position / duration : 0)
                Text(MediaDisplay.remainingText(position: position, duration: duration))
                    .frame(minWidth: 30, alignment: .trailing)
                    .fixedSize()
            }
            .font(DesignTokens.Fonts.rowMeta)
            .foregroundStyle(DesignTokens.Colors.secondaryText)
        }
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let current = snapshot.position(at: Date())
            switch direction {
            case .increment: onSeek(current + 10)
            case .decrement: onSeek(current - 10)
            @unknown default: break
            }
        }
        .onDisappear { endScrub() }
    }

    private var accessibilityValue: String {
        let position = snapshot.position(at: Date())
        return "\(PlaybackSnapshot.formatTime(position)) of \(PlaybackSnapshot.formatTime(duration))"
    }

    private func displayedPosition(at date: Date) -> Double {
        if let dragFraction { return dragFraction * duration }
        return snapshot.position(at: date)
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.Colors.trackFill)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * width)
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
        }
        .frame(height: 14)
        .onHover { isHovering = $0 }
        .animation(DesignTokens.Motion.hover, value: barHeight)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled, width > 0 else { return }
                if holdToken == nil { holdToken = notch.holdOpen(reason: "media.scrub") }
                dragFraction = fraction(for: value.location.x, width: width)
            }
            .onEnded { value in
                defer { endScrub() }
                guard isEnabled, width > 0, duration > 0 else { return }
                onSeek(fraction(for: value.location.x, width: width) * duration)
            }
    }

    private func fraction(for x: CGFloat, width: CGFloat) -> Double {
        min(max(Double(x / width), 0), 1)
    }

    private func endScrub() {
        dragFraction = nil
        holdToken?.release()
        holdToken = nil
    }
}

// MARK: - Empty / permission states

/// Icon, one line of title, an optional detail and an optional glass button, centred in the column.
struct MediaEmptyStateView: View {
    let symbol: String
    let title: String
    var detail: String?
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.secondaryText)
            Text(title)
                .font(DesignTokens.Fonts.bodyEmphasized)
                .foregroundStyle(DesignTokens.Colors.primaryText)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
