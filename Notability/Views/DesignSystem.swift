import SwiftUI

// MARK: - Tokens

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum CornerRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let pill: CGFloat = 999
}

enum BrandColor {
    static let accent = Color.accentColor
    static let recording = Color(red: 0.92, green: 0.27, blue: 0.31)
    static let success = Color(red: 0.18, green: 0.74, blue: 0.45)
    static let warning = Color(red: 0.95, green: 0.65, blue: 0.20)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.5)
}

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                    .strokeBorder(BrandColor.border, lineWidth: 0.5)
            )
    }
}

// MARK: - Section header

struct SectionTitle: View {
    let text: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
    }
}

// MARK: - Pill / badge

struct Pill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Branded empty state

struct BrandedEmptyState: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var action: (label: String, perform: () -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .padding(Spacing.lg)
                .background(BrandColor.surface, in: Circle())
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let action {
                Button(action.label, action: action.perform)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

// MARK: - Pulsing dot (used by recording indicator + sidebar status)

struct PulsingDot: View {
    var color: Color = BrandColor.recording
    var size: CGFloat = 10
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.4, height: size * 2.4)
                .scaleEffect(animate ? 1.0 : 0.4)
                .opacity(animate ? 0 : 0.7)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

// MARK: - Primary CTA

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = BrandColor.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }
}

