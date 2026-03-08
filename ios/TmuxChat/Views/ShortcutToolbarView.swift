import SwiftUI

struct ShortcutToolbarView: View {
    let layout: ShortcutToolbarLayout
    let modifierState: ShortcutModifierStateMachine
    var onItemTapped: (ShortcutToolbarItem) -> Void

    private func modifierStateColor(_ state: ShortcutModifierActivationState) -> Color {
        switch state {
        case .off:
            return Color(.secondarySystemBackground)
        case .oneShot:
            return .blue.opacity(0.25)
        case .locked:
            return .blue
        }
    }

    private func labelColor(for state: ShortcutModifierActivationState) -> Color {
        switch state {
        case .locked:
            return .white
        case .off, .oneShot:
            return .primary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if modifierState.hasActiveModifiers {
                Text("Pending: \(modifierState.activeModifiersLabel)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(layout.items) { item in
                        Button {
                            onItemTapped(item)
                        } label: {
                            switch item.kind {
                            case .modifier(let modifier):
                                let state = modifierState.state(for: modifier)
                                Text(item.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(labelColor(for: state))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(minHeight: 44)
                                    .background(
                                        Capsule().fill(modifierStateColor(state))
                                    )
                            case .key:
                                Text(item.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(minHeight: 44)
                                    .background(
                                        Capsule().fill(Color(.secondarySystemBackground))
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityLabel("Shortcut toolbar")
    }
}
