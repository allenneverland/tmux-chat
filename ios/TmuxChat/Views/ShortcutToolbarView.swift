import SwiftUI

struct ShortcutToolbarView: View {
    @State private var layoutManager = ShortcutLayoutManager.shared

    @Binding var isCollapsed: Bool
    var isSending: Bool
    var onKeyTapped: (ShortcutItem) -> Void

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
            }

            if !isCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layoutManager.selectedGroupItems) { item in
                            Button {
                                onKeyTapped(item)
                            } label: {
                                Text(item.displayLabel)
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
