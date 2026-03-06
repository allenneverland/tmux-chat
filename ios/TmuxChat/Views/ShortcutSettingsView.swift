import SwiftUI
import UniformTypeIdentifiers

struct ShortcutSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var layoutManager = ShortcutLayoutManager.shared
    @State private var isDropTargeted = false
    @State private var showAddGroupAlert = false
    @State private var addGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renameGroupID: UUID?
    @State private var renameGroupName = ""

    var body: some View {
        NavigationStack {
            List {
                groupsSection
                selectedRowSection
                selectedOrderSection
                allKeysSection
            }
            .navigationTitle("Shortcut Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .alert("Add Group", isPresented: $showAddGroupAlert) {
                TextField("Group name", text: $addGroupName)
                Button("Cancel", role: .cancel) {
                    addGroupName = ""
                }
                Button("Add") {
                    layoutManager.addGroup(named: addGroupName)
                    addGroupName = ""
                }
            } message: {
                Text("Create a custom shortcut group")
            }
            .alert("Rename Group", isPresented: $showRenameGroupAlert) {
                TextField("Group name", text: $renameGroupName)
                Button("Cancel", role: .cancel) {
                    renameGroupID = nil
                    renameGroupName = ""
                }
                Button("Save") {
                    if let renameGroupID {
                        layoutManager.renameGroup(id: renameGroupID, to: renameGroupName)
                    }
                    renameGroupID = nil
                    renameGroupName = ""
                }
            } message: {
                Text("Update the group name")
            }
        }
    }

    private var groupsSection: some View {
        Section {
            ForEach(layoutManager.groups) { group in
                HStack(spacing: 12) {
                    Button {
                        layoutManager.selectGroup(group.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(group.name)
                            Text("(\(group.items.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if layoutManager.selectedGroupID == group.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button {
                        renameGroupID = group.id
                        renameGroupName = group.name
                        showRenameGroupAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete { offsets in
                layoutManager.deleteGroups(at: offsets)
            }
            .onMove { source, destination in
                layoutManager.moveGroups(from: source, to: destination)
            }

            Button {
                showAddGroupAlert = true
            } label: {
                Label("Add Group", systemImage: "plus")
            }
        } header: {
            Text("Groups")
        } footer: {
            Text("Create, rename, reorder, and switch shortcut groups.")
        }
    }

    @ViewBuilder
    private var selectedRowSection: some View {
        if let selectedGroup = layoutManager.selectedGroup {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if selectedGroup.items.isEmpty {
                            Text("Drop keys here")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(selectedGroup.items) { item in
                                if let key = layoutManager.key(for: item) {
                                    HStack(spacing: 4) {
                                        Text(key.label)
                                            .font(.caption.weight(.semibold))
                                        Button {
                                            layoutManager.removeItem(item.id, from: selectedGroup.id)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .onDrop(
                    of: [UTType.plainText],
                    isTargeted: $isDropTargeted,
                    perform: { providers in
                        handleDrop(providers: providers, groupID: selectedGroup.id)
                    }
                )
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [4])
                        )
                )
            } header: {
                Text("Current Row")
            } footer: {
                Text("Drag any key from the catalog below into this row.")
            }
        }
    }

    @ViewBuilder
    private var selectedOrderSection: some View {
        if let selectedGroup = layoutManager.selectedGroup {
            Section {
                if selectedGroup.items.isEmpty {
                    Text("No keys in this group")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(selectedGroup.items.enumerated()), id: \.element.id) { index, item in
                        if let key = layoutManager.key(for: item) {
                            HStack {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(key.label)
                                Spacer()
                                Text(key.tmuxToken)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        layoutManager.deleteItems(in: selectedGroup.id, at: offsets)
                    }
                    .onMove { source, destination in
                        layoutManager.moveItems(in: selectedGroup.id, from: source, to: destination)
                    }
                }
            } header: {
                Text("Order & Remove")
            }
        }
    }

    private var allKeysSection: some View {
        Section {
            ForEach(ShortcutCatalogCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 10) {
                    Text(category.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                        ForEach(ShortcutCatalog.keys(for: category)) { key in
                            Text(key.label)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Color(.systemGray6), in: Capsule())
                                .onDrag {
                                    NSItemProvider(object: "catalog:\(key.id)" as NSString)
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("All Keys")
        } footer: {
            Text("Long-press and drag keys into the current row.")
        }
    }

    private func handleDrop(providers: [NSItemProvider], groupID: UUID) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payloadObject = object as? NSString else { return }
            let payload = payloadObject as String
            DispatchQueue.main.async {
                layoutManager.handleDropPayload(payload, to: groupID)
            }
        }
        return true
    }
}
