import LiteSpaceCore
import SwiftUI

struct ShortcutBar: View {
    @ObservedObject var session: TerminalSessionCoordinator

    private let keys: [(TerminalShortcutKey, String)] = [
        (.escape, "Esc"),
        (.control, "Ctrl"),
        (.tab, "Tab"),
        (.up, "↑"),
        (.down, "↓"),
        (.left, "←"),
        (.right, "→"),
        (.slash, "/")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.0) { key, label in
                    Button {
                        session.handleShortcut(key)
                    } label: {
                        Text(label)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(minWidth: 44, minHeight: 44)
                            .background(buttonBackground(for: key), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("shortcut.\(label)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func buttonBackground(for key: TerminalShortcutKey) -> Color {
        if key == .control, session.isControlLatched {
            return Color.accentColor
        }
        return Color.white.opacity(0.12)
    }
}
