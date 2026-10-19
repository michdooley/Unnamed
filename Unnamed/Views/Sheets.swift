import SwiftUI
import UnnamedKit

/// Asks for a name (new collection, rename).
struct NamePromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var prompt: NamePrompt
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title)
                .font(.headline)
            TextField("Name", text: $prompt.text, prompt: Text("Album, EP, mixtape…"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func confirm() {
        model.commit(prompt)
        dismiss()
    }
}

/// Picks tracks already in the library to add to a collection (for mixtapes).
struct TrackPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let store: LibraryStore
    let collectionID: UUID

    @State private var selected: Set<UUID> = []
    @State private var query = ""

    var body: some View {
        let existing = Set(store.collections[collectionID]?.trackIDs ?? [])
        let tracks = store.tracksNewestFirst.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
        }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add to “\(store.collections[collectionID]?.title ?? "")”")
                    .font(.headline)
                TextField("Filter", text: $query, prompt: Text("Filter tracks"))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(20)

            List(tracks) { track in
                let alreadyIn = existing.contains(track.id)
                Toggle(isOn: Binding(
                    get: { alreadyIn || selected.contains(track.id) },
                    set: { isOn in
                        if isOn { selected.insert(track.id) } else { selected.remove(track.id) }
                    }
                )) {
                    HStack(spacing: 10) {
                        TrackArtworkView(trackID: track.id, cornerRadius: 5, pixelSize: 80)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text(subtitle(for: track))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(alreadyIn)
            }
            .listStyle(.inset)

            HStack {
                Text(selected.isEmpty ? "" : "\(selected.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.count > 1 ? "Add \(selected.count) Tracks" : "Add Track") {
                    let ordered = store.tracksNewestFirst.map(\.id).filter(selected.contains)
                    store.addTracks(ordered, to: collectionID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
    }

    private func subtitle(for track: Track) -> String {
        let names = store.collections(containing: track.id).map(\.title)
        let date = Format.date(track.createdAt)
        return names.isEmpty ? date : "\(date) · \(names.joined(separator: ", "))"
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Library") {
                if let store = model.store {
                    LabeledContent("Location") {
                        Text(store.root.path)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Sync") {
                        Label(
                            store.isInCloud ? "iCloud Drive" : "This Mac only (not syncing)",
                            systemImage: store.isInCloud ? "icloud" : "internaldrive"
                        )
                    }
                } else {
                    Text("No library open.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show in Finder") { model.revealLibraryInFinder() }
                        .disabled(model.store == nil)
                    Button("Open Library…") { model.chooseExistingLibrary() }
                    Button("Create Library…") { model.createLibraryInICloud() }
                }
            }
            Section {
                TextField("Your name", text: $model.authorName)
            } header: {
                Text("Comments")
            } footer: {
                Text("Shown next to comments you write, so collaborators sharing the folder know who said what.")
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Unnamed is open source. Your library is plain files — audio, JSON and Markdown — in a folder you control. Nothing is uploaded anywhere except your own iCloud Drive.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}
