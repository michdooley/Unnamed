import SwiftUI
import UnnamedKit

/// Everything archived: out of sight, not deleted. Restoring puts things back
/// exactly where they were.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    @State private var isTargeted = false

    var body: some View {
        let folders = store.archivedFolders
        let collections = store.archivedCollections
        let tracks = store.archivedTracks
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Archived")
                            .font(.system(size: 30, weight: .semibold))
                        Text("Out of sight, not deleted. Restore anything to put it back where it was.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                if folders.isEmpty && collections.isEmpty && tracks.isEmpty {
                    VStack(spacing: 6) {
                        Text("Nothing archived")
                            .font(.system(size: 15, weight: .medium))
                        Text("Right-click a track, collection or folder and choose Archive, or drag it onto Archived in the sidebar.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                }

                if !folders.isEmpty || !collections.isEmpty {
                    CenteredFlowLayout(spacing: 32, rowSpacing: 32, centered: false) {
                        ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                            FolderCard(store: store, folder: folder, size: 170)
                                .overlay(alignment: .topLeading) { RestoreBadge(item: .folder(folder.id)) }
                                .cascadeIn(index)
                        }
                        ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                            CollectionCard(store: store, collection: collection, size: 170)
                                .overlay(alignment: .topLeading) { RestoreBadge(item: .collection(collection.id)) }
                                .cascadeIn(folders.count + index)
                        }
                    }
                    .padding(.top, 32)
                }

                if !tracks.isEmpty {
                    Text("Tracks")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.top, 36)
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(store: store, track: track, queue: tracks.map(\.id), showsCollections: true)
                                .cascadeIn(index)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .pageEntrance()
        .dropHighlight(isTargeted, cornerRadius: 0)
        // Dropping things here archives them.
        .onDrop(of: [.unnamedItem], isTargeted: $isTargeted) { providers in
            Task {
                for item in await DropPayload.load(from: providers).items { model.archive(item) }
            }
            return true
        }
    }
}

/// A small "Restore" button over an archived card.
struct RestoreBadge: View {
    @Environment(AppModel.self) private var model
    let item: LibraryItemRef
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        Button {
            model.restore(item)
        } label: {
            Label("Restore", systemImage: "arrow.uturn.backward")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Capsule())
                .glassOr(glass, in: Capsule(), interactive: true, classic: .regularMaterial)
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Put it back where it was")
    }
}

/// Shown at the top of an archived collection or folder (or one inside an archived folder).
struct ArchivedBanner: View {
    @Environment(AppModel.self) private var model
    let root: LibraryItemRef
    /// Whether the page itself is the archived thing (vs. inside an archived folder).
    let isSelf: Bool
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(isSelf ? "Restore" : "Restore Folder") { model.restore(root) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassOr(glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous), classic: Color.primary.opacity(0.05))
    }

    private var message: String {
        if isSelf {
            switch root {
            case .folder: return "This folder is archived, along with everything in it."
            default: return "This collection is archived. It's hidden from Home and your library."
            }
        }
        return "This is inside the archived folder “\(model.title(of: root))”."
    }
}

/// The message at the bottom of the window ("Archived “Snippets” · Undo").
struct ToastView: View {
    let toast: Toast
    var dismiss: () -> Void
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.secondary)
            Text(toast.message)
                .lineLimit(1)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    dismiss()
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(ToastSurface(glass: glass))
    }
}

private struct ToastSurface: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content.glassOr(true, in: Capsule(), classic: Color.clear)
        } else {
            content
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}
