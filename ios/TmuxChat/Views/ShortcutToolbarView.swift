import SwiftUI

struct ShortcutToolbarView: View {
    @State private var layoutManager = ShortcutLayoutManager.shared

    @Binding var isCollapsed: Bool
    @Binding var modifierSelection: ShortcutModifierSelection
    var isSending: Bool
    var onOpenSettings: () -> Void
    var onKeyTapped: (ShortcutCatalogKey, Set<ShortcutModifier>) -> Void

    private var selectedGroupName: String {
        layoutManager.selectedGroup?.name ?? "Group"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Label(
                        isCollapsed ? "Show" : "Hide",
                        systemImage: isCollapsed ? "chevron.up.circle" : "chevron.down.circle"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(layoutManager.groups) { group in
                        Button(group.name) {
                            layoutManager.selectGroup(group.id)
                        }
                    }
                } label: {
                    Label(selectedGroupName, systemImage: "square.grid.2x2")
                        .font(.subheadline.weight(.medium))
                }

                Spacer()

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            if !isCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ShortcutModifier.allCases) { modifier in
                            ModifierChip(
                                modifier: modifier,
                                state: modifierSelection.state(for: modifier)
                            ) {
                                modifierSelection.cycle(modifier)
                            }
                            .disabled(isSending)
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layoutManager.selectedGroupKeys) { key in
                            Button {
                                onKeyTapped(key, modifierSelection.activeModifiers)
                            } label: {
                                Text(key.label)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSending)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct ModifierChip: View {
    let modifier: ShortcutModifier
    let state: ShortcutModifierState
    let onTap: () -> Void

    private var tint: Color {
        switch state {
        case .off:
            return .gray
        case .oneShot:
            return .blue
        case .locked:
            return .green
        }
    }

    private var suffix: String {
        switch state {
        case .off:
            return ""
        case .oneShot:
            return "•"
        case .locked:
            return "∞"
        }
    }

    var body: some View {
        Button(action: onTap) {
            Text(modifier.displayName + suffix)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(state == .off ? Color.primary : Color.white)
                .background(
                    Capsule().fill(state == .off ? Color(.systemGray5) : tint)
                )
        }
        .buttonStyle(.plain)
    }
}
