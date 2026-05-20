import SwiftUI

struct TranscriptRow: View {
    let timestamp: TimeInterval
    let text: String
    var isFailure: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(formatTimestamp(timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 4)
            Text(text)
                .font(.system(size: 14))
                .italic(isFailure)
                .foregroundStyle(isFailure ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(BrandColor.surface, in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(BrandColor.border, lineWidth: 0.5)
                )
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
