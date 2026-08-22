import SwiftUI

struct TranscriptRow: View {
    let chunk: TranscriptChunk

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(formatTimestamp(chunk.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Above the text rather than in the timestamp gutter: diarization
                // labels are of unbounded length, and a fixed-width gutter would
                // clip them. Left-aligned so labels line up down the transcript
                // and can be scanned without reading the turns.
                if let speaker = chunk.displaySpeaker {
                    Pill(text: speaker, tint: BrandColor.accent)
                }
                Text(chunk.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
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
