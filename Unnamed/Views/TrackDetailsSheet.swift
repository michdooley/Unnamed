import SwiftUI
import UnnamedKit

/// The track modal: a summary with the disc and waveform on the left,
/// actions (and the Notes / Comments / Versions / Edit panes) on the right.
struct TrackDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID
    let collectionID: UUID?

    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let store = model.store, let track = store.tracks[trackID] {
                HStack(spacing: 0) {
                    TrackSummary(store: store, track: track, collectionID: collectionID)
                        .frame(width: 330)
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        pane(store: store, track: track)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            } else {
                ContentUnavailableView("Track Deleted", systemImage: "trash")
            }
        }
        .frame(width: 820, height: 580)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(16)
        }
        .confirmationDialog(
            "Delete “\(model.store?.tracks[trackID]?.title ?? "track")”?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Track", role: .destructive) {
                dismiss()
                model.confirmDeletion(.track(trackID))
            }
        } message: {
            Text("The track, its notes and comments move to the Trash, and it's removed from every collection.")
        }
    }

    private var pane: TrackDetailPane {
        model.detail?.pane ?? .actions
    }

    private func show(_ pane: TrackDetailPane) {
        model.detail?.pane = pane
    }

    private var header: some View {
        HStack(spacing: 6) {
            if pane == .actions {
                Text("Details")
            } else {
                Button {
                    show(.actions)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("Details")
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text("/").foregroundStyle(.tertiary)
                Text(paneTitle)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var paneTitle: String {
        switch pane {
        case .actions: "Details"
        case .notes: "Notes"
        case .comments: "Comments"
        case .edit: "Edit track"
        case .versions: "Versions"
        case .addToCollection: "Add to collection"
        case .moveToCollection: "Move to"
        case .folder: "Folder"
        }
    }

    @ViewBuilder
    private func pane(store: LibraryStore, track: Track) -> some View {
        switch pane {
        case .actions:
            actions(store: store, track: track)
        case .notes:
            NotesPane(store: store, trackID: trackID)
        case .comments:
            CommentsPane(store: store, trackID: trackID, collectionID: collectionID)
        case .edit:
            EditTrackPane(store: store, track: track)
        case .versions:
            VersionsPane(store: store, track: track, collectionID: collectionID)
        case .folder:
            FolderChooserPane(store: store, trackID: trackID)
        case .addToCollection:
            CollectionChooserPane(store: store, trackID: trackID, mode: .add)
        case .moveToCollection:
            CollectionChooserPane(store: store, trackID: trackID, mode: .move(from: collectionID)) {
                dismiss()
            }
        }
    }

    private func actions(store: LibraryStore, track: Track) -> some View {
        let commentCount = store.comments[trackID]?.count ?? 0
        let status = store.cloudStatus[trackID]
        let audioURL = store.audioURL(for: trackID)
        let folderTitle = store.folder(ofTrack: trackID).flatMap { store.folders[$0]?.title }
        return ScrollView {
            VStack(spacing: 16) {
                ActionGroup {
                    ActionRow(title: "Upload new version", systemImage: "waveform.badge.plus") {
                        model.uploadNewVersion(of: trackID)
                    }
                    RowDivider()
                    ActionRow(
                        title: "Versions",
                        systemImage: "clock.arrow.circlepath",
                        detail: track.versions.count == 1 ? "1 version" : "\(track.versions.count) versions",
                        showsChevron: true
                    ) {
                        show(.versions)
                    }
                    RowDivider()
                    ActionRow(title: "Notes", systemImage: "doc.text", detail: store.notes[trackID] == nil ? nil : "Has notes", showsChevron: true) {
                        show(.notes)
                    }
                    RowDivider()
                    ActionRow(title: "Comments", systemImage: "bubble.left", detail: commentCount > 0 ? "\(commentCount)" : nil, showsChevron: true) {
                        show(.comments)
                    }
                    RowDivider()
                    ActionRow(title: "Edit track", systemImage: "slider.horizontal.3", showsChevron: true) {
                        show(.edit)
                    }
                    if store.isInCloud {
                        RowDivider()
                        if status == .notDownloaded || status == .downloading {
                            ActionRow(title: status == .downloading ? "Downloading…" : "Make available offline", systemImage: "arrow.down.circle") {
                                store.download(trackID)
                            }
                            .disabled(status == .downloading)
                        } else {
                            ActionRow(title: "Remove download", systemImage: "icloud.and.arrow.up", detail: "Keeps it in iCloud") {
                                store.removeDownload(trackID)
                            }
                        }
                    }
                    RowDivider()
                    ActionRow(title: "Add to queue", systemImage: "text.badge.plus") {
                        player.addToQueue(trackID)
                    }
                }

                ActionGroup {
                    ActionRow(title: "Export audio", systemImage: "arrow.down.to.line") {
                        model.exportAudio(of: trackID)
                    }
                    RowDivider()
                    if let audioURL {
                        ShareLink(item: audioURL, subject: Text(track.title)) {
                            ActionRowLabel(title: "Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                        RowDivider()
                    }
                    ActionRow(title: "Add to collection", systemImage: "square.stack", showsChevron: true) {
                        show(.addToCollection)
                    }
                    if collectionID != nil {
                        RowDivider()
                        ActionRow(title: "Move", systemImage: "arrow.right.square", showsChevron: true) {
                            show(.moveToCollection)
                        }
                    }
                    RowDivider()
                    ActionRow(title: "Folder", systemImage: "folder", detail: folderTitle ?? "None", showsChevron: true) {
                        show(.folder)
                    }
                    RowDivider()
                    ActionRow(title: "Duplicate", systemImage: "plus.square.on.square") {
                        model.duplicate(trackID: trackID, in: collectionID)
                    }
                    RowDivider()
                    ActionRow(title: "Show in Finder", systemImage: "arrow.up.forward.square") {
                        model.revealInFinder(trackID: trackID)
                    }
                }

                ActionGroup {
                    if let collectionID {
                        ActionRow(title: "Remove from collection", systemImage: "minus.circle") {
                            dismiss()
                            store.removeTracks([trackID], from: collectionID)
                        }
                        RowDivider()
                    }
                    ActionRow(title: "Delete", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Summary column

private struct TrackSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let track: Track
    let collectionID: UUID?

    @State private var dropTargeted = false

    var body: some View {
        let isCurrent = player.currentTrackID == track.id
        let artwork = model.artwork(forTrack: track.id, in: collectionID)
        // The version on screen: the one playing, else the current one.
        let shown = player.playingVersion(of: track.id) ?? track.currentVersionID
        let length = track.version(shown)?.duration ?? track.duration
        let comments = store.comments(for: track.id, version: shown)
        VStack(spacing: 0) {
            Spacer(minLength: 44)
            DiscView(artworkURL: artwork.url, seed: artwork.seed, spinning: isCurrent && player.isPlaying)
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .onTapGesture { togglePlay() }
            Text(track.title)
                .font(.system(size: 19, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 22)
                .padding(.horizontal, 24)
            Text(Format.length(isCurrent && player.duration > 0 ? player.duration : length))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if track.versions.count > 1, let shown {
                HStack(spacing: 4) {
                    Text("\(track.versionLabel(of: shown)) of \(track.versions.count)")
                    if shown != track.currentVersionID {
                        Text("· not current").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            }
            if track.bpm != nil || track.musicalKey != nil {
                Text([track.bpm.map { String(format: "%g BPM", $0) }, track.musicalKey].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }

            WaveformView(
                peaks: store.peaks(for: track.id, version: shown),
                progress: isCurrent ? player.progress : 0,
                style: .detail,
                showsPlayhead: isCurrent,
                duration: length,
                markers: comments.map { comment in
                    WaveformView.Marker(
                        id: comment.id,
                        fraction: length > 0 ? min(1, comment.timestamp / length) : 0,
                        label: "\(Format.clock(comment.timestamp)) — \(comment.text)"
                    )
                },
                onSeek: { fraction in play(at: fraction * length, version: shown) },
                onMarkerTap: { marker in
                    if let comment = comments.first(where: { $0.id == marker.id }) { play(at: comment.timestamp, version: shown) }
                }
            )
            .frame(height: 38)
            .padding(.horizontal, 26)
            .padding(.top, 30)

            HStack {
                Text(Format.clock(isCurrent ? player.currentTime : 0))
                Spacer()
                Text(Format.clock(length))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 26)
            .padding(.top, comments.isEmpty ? 8 : 18)

            Button(action: togglePlay) {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)

            Spacer(minLength: 20)

            let names = store.collections(containing: track.id).map(\.title)
            if !names.isEmpty {
                Text("In \(names.joined(separator: ", "))")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay(
                        Label("Drop to add a new version", systemImage: "waveform.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        // Drop an audio file anywhere on the summary to add it as a new version.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let payload = await DropPayload.load(from: providers)
                if let url = payload.fileURLs.first {
                    await model.addVersion(to: track.id, from: url)
                }
            }
            return true
        }
    }

    private var queue: [UUID] {
        collectionID.flatMap { store.collections[$0]?.trackIDs } ?? [track.id]
    }

    private func togglePlay() {
        player.playOrToggle(trackID: track.id, in: queue, context: collectionID)
    }

    private func play(at time: TimeInterval, version: UUID?) {
        player.play(trackID: track.id, version: version, at: time, in: queue, context: collectionID)
    }
}

// MARK: - Notes

private struct NotesPane: View {
    let store: LibraryStore
    let trackID: UUID

    var body: some View {
        let text = Binding(
            get: { store.notes[trackID] ?? "" },
            set: { store.setNotes($0, for: trackID) }
        )
        TextEditor(text: text)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Lyrics, chords, what to fix next…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 17)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
    }
}

// MARK: - Comments

private struct CommentsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let trackID: UUID
    let collectionID: UUID?

    @State private var draft = ""
    /// The playhead when the user started typing, so the comment lands where they meant.
    @State private var pinnedTime: TimeInterval?
    /// A version picked in the menu; otherwise the one playing or current.
    @State private var pickedVersion: UUID?
    @FocusState private var composerFocused: Bool

    private var track: Track? { store.tracks[trackID] }

    /// Comments are per version: a new mix gets a fresh set.
    private var shownVersion: UUID? {
        // A picked version may have been deleted since (here or on another device).
        let picked = pickedVersion.flatMap { id in track?.version(id) != nil ? id : nil }
        return picked ?? player.playingVersion(of: trackID) ?? track?.currentVersionID
    }

    var body: some View {
        let comments = store.comments(for: trackID, version: shownVersion)
        VStack(spacing: 0) {
            if let track, track.versions.count > 1, let shown = shownVersion {
                HStack {
                    Menu {
                        ForEach(track.versions.reversed()) { version in
                            let count = store.comments(for: trackID, version: version.id).count
                            Button {
                                pickedVersion = version.id
                            } label: {
                                Text("\(track.versionLabel(of: version.id))\(version.id == track.currentVersionID ? " (current)" : "") — \(count) comment\(count == 1 ? "" : "s")")
                            }
                        }
                    } label: {
                        Text("On \(track.versionLabel(of: shown))")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            if comments.isEmpty {
                ContentUnavailableView(
                    "No Comments Yet",
                    systemImage: "bubble.left",
                    description: Text("Play the track and leave a note at the exact moment — “bass too loud here”, “keep this take”.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(comments) { comment in
                            CommentRow(store: store, trackID: trackID, collectionID: collectionID, comment: comment, version: shownVersion)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TimestampChip(time: pinnedTime ?? liveTime)
                TextField("Comment at \(Format.clock(pinnedTime ?? liveTime))…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit(post)
                Button("Post", action: post)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .onChange(of: draft) { old, new in
            if old.isEmpty, !new.isEmpty { pinnedTime = liveTime }
            if new.isEmpty { pinnedTime = nil }
        }
        .onAppear { composerFocused = true }
    }

    private var liveTime: TimeInterval {
        player.playingVersion(of: trackID) == shownVersion ? player.currentTime : 0
    }

    private func post() {
        guard store.addComment(to: trackID, at: pinnedTime ?? liveTime, text: draft, author: model.authorName, version: shownVersion) != nil else { return }
        draft = ""
        pinnedTime = nil
    }
}

private struct CommentRow: View {
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let trackID: UUID
    let collectionID: UUID?
    let comment: TrackComment
    /// The version this comment is on, so clicking its time plays that mix.
    var version: UUID?

    @State private var hovering = false
    @State private var editing = false
    @State private var editText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimestampChip(time: comment.timestamp) {
                let queue = collectionID.flatMap { store.collections[$0]?.trackIDs } ?? [trackID]
                player.play(trackID: trackID, version: version, at: comment.timestamp, in: queue, context: collectionID)
            }
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField("Comment", text: $editText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    HStack {
                        Button("Cancel") { editing = false }
                        Button("Save", action: save).keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                } else {
                    Text(comment.text)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text([comment.author, comment.createdAt.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if hovering && !editing {
                HStack(spacing: 2) {
                    Button {
                        editText = comment.text
                        editing = true
                    } label: {
                        Image(systemName: "pencil").frame(width: 24, height: 24)
                    }
                    .help("Edit")
                    Button {
                        store.deleteComment(comment.id, from: trackID)
                    } label: {
                        Image(systemName: "trash").frame(width: 24, height: 24)
                    }
                    .help("Delete")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }

    private func save() {
        store.updateComment(comment.id, on: trackID, text: editText)
        editing = false
    }
}

// MARK: - Edit

private struct EditTrackPane: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let track: Track

    @State private var title = ""
    @State private var bpm = ""
    @State private var key = ""
    /// What the fields held when last loaded or saved, so only real edits are
    /// written (and a rename synced from another device isn't overwritten).
    @State private var saved = (title: "", bpm: "", key: "")
    @State private var saveTask: Task<Void, Never>?

    static let keys: [String] = {
        let notes = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return notes.map { "\($0) major" } + notes.map { "\($0) minor" }
    }()

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                    .onSubmit(commit)
            }
            Section("Artwork") {
                HStack(spacing: 14) {
                    TrackArtworkView(trackID: track.id, cornerRadius: 8, pixelSize: 160)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Choose Image…") { model.chooseArtwork(forTrack: track.id) }
                        if track.artworkFileName != nil {
                            Button("Use Collection Artwork") { store.removeArtwork(forTrack: track.id) }
                        }
                    }
                }
            }
            Section("Musical details") {
                TextField("BPM", text: $bpm, prompt: Text("e.g. 120"))
                    .onSubmit(commit)
                Picker("Key", selection: $key) {
                    Text("None").tag("")
                    ForEach(Self.keys, id: \.self) { Text($0).tag($0) }
                    if !key.isEmpty, !Self.keys.contains(key) {
                        Text(key).tag(key)
                    }
                }
            }
            Section("File") {
                LabeledContent("Added", value: Format.date(track.createdAt))
                LabeledContent("Length", value: Format.clock(track.duration))
                if let original = track.originalFileName {
                    LabeledContent("Original file", value: original)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            title = track.title
            bpm = track.bpm.map { String(format: "%g", $0) } ?? ""
            key = track.musicalKey ?? ""
            saved = (title, bpm, key)
        }
        .onChange(of: title) { scheduleCommit() }
        .onChange(of: bpm) { scheduleCommit() }
        .onChange(of: key) { commit() }
        .onDisappear(perform: commit)
    }

    private func scheduleCommit() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        saveTask?.cancel()
        let changedTitle = title != saved.title
        let changedBPM = bpm != saved.bpm
        let changedKey = key != saved.key
        guard changedTitle || changedBPM || changedKey else { return }
        let parsedBPM = Double(bpm.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        store.updateTrack(track.id) { track in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if changedTitle, !trimmed.isEmpty { track.title = trimmed }
            if changedBPM { track.bpm = parsedBPM.flatMap { $0 > 0 ? $0 : nil } }
            if changedKey { track.musicalKey = key.isEmpty ? nil : key }
        }
        saved = (title, bpm, key)
    }
}

// MARK: - Add / move to collection

private struct CollectionChooserPane: View {
    enum Mode {
        case add
        case move(from: UUID?)
    }

    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let trackID: UUID
    let mode: Mode
    var onMoved: () -> Void = {}

    @State private var newName = ""

    var body: some View {
        let collections = model.orderedCollections.filter { collection in
            if case .move(let source) = mode { return collection.id != source }
            return true
        }
        ScrollView {
            VStack(spacing: 16) {
                ActionGroup {
                    ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                        if index > 0 { RowDivider() }
                        let contains = collection.trackIDs.contains(trackID)
                        Button {
                            choose(collection.id, contains: contains)
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: store.artworkURL(forCollection: collection.id), seed: collection.id, cornerRadius: 5, pixelSize: 80)
                                    .frame(width: 28, height: 28)
                                Text(collection.title)
                                    .font(.system(size: 15))
                                    .lineLimit(1)
                                Spacer()
                                if case .add = mode, contains {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("New collection", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createCollection)
                    Button("Create", action: createCollection)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func choose(_ collectionID: UUID, contains: Bool) {
        switch mode {
        case .add:
            if contains {
                store.removeTracks([trackID], from: collectionID)
            } else {
                store.addTracks([trackID], to: collectionID)
            }
        case .move(let source):
            if let source {
                store.moveTracks([trackID], from: source, to: collectionID)
            } else {
                store.addTracks([trackID], to: collectionID)
            }
            onMoved()
        }
    }

    private func createCollection() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let collection = store.createCollection(title: name)
        newName = ""
        choose(collection.id, contains: false)
    }
}

// MARK: - Versions

/// Every version of the track, newest first: play any of them, make one
/// current, name, export or delete them.
private struct VersionsPane: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let track: Track
    let collectionID: UUID?

    @State private var pendingDelete: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ActionGroup {
                    ActionRow(title: "Upload new version…", systemImage: "waveform.badge.plus") {
                        model.uploadNewVersion(of: track.id)
                    }
                }
                Text("New versions become current; older ones stay here. You can also drop an audio file on the disc.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ActionGroup {
                    let versions = Array(track.versions.reversed())
                    ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                        if index > 0 { RowDivider() }
                        VersionRow(store: store, track: track, version: version, collectionID: collectionID) {
                            pendingDelete = version.id
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete \(track.versionLabel(of: $0))?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { versionID in
            Button("Delete Version", role: .destructive) {
                store.deleteVersion(versionID, of: track.id)
                model.player.libraryDidChange()
            }
        } message: { versionID in
            let count = store.comments(deletedWith: versionID, of: track.id).count
            Text("Its audio moves to the Trash\(count > 0 ? " and its \(count) comment\(count == 1 ? "" : "s") will be deleted" : "").")
        }
    }
}

private struct VersionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    let store: LibraryStore
    let track: Track
    let version: TrackVersion
    let collectionID: UUID?
    let onDelete: () -> Void

    @State private var renaming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let isCurrent = version.id == track.currentVersionID
        let isLoaded = player.playingVersion(of: track.id) == version.id
        let number = track.versionNumber(of: version.id) ?? 0
        HStack(alignment: .top, spacing: 12) {
            Button {
                if isLoaded {
                    player.togglePlayPause()
                } else {
                    let queue = collectionID.flatMap { store.collections[$0]?.trackIDs } ?? [track.id]
                    player.play(trackID: track.id, version: version.id, in: queue, context: collectionID)
                }
            } label: {
                Image(systemName: isLoaded && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(isLoaded ? 1 : 0.75)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isLoaded && player.isPlaying ? "Pause" : "Play v\(number)")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("v\(number)")
                        .font(.system(size: 15, weight: .semibold))
                    if renaming {
                        TextField("Name this version", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .focused($nameFocused)
                            .onSubmit(saveName)
                            .onExitCommand { renaming = false }
                    } else if let label = version.name {
                        Text(label)
                            .font(.system(size: 14))
                            .lineLimit(1)
                    }
                    if isCurrent {
                        Text("Current")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text([Format.date(version.createdAt), Format.length(version.duration), version.originalFileName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                WaveformView(
                    peaks: store.peaks(for: track.id, version: version.id),
                    progress: isLoaded ? player.progress : 0,
                    style: .detail,
                    showsPlayhead: isLoaded,
                    duration: version.duration,
                    onSeek: { fraction in
                        let queue = collectionID.flatMap { store.collections[$0]?.trackIDs } ?? [track.id]
                        player.play(trackID: track.id, version: version.id, at: fraction * version.duration, in: queue, context: collectionID)
                    }
                )
                .frame(height: 22)
                .padding(.top, 2)
            }

            Menu {
                if !isCurrent {
                    Button("Make Current") {
                        store.setCurrentVersion(version.id, of: track.id)
                        player.libraryDidChange()
                    }
                }
                Button(version.name == nil ? "Name Version…" : "Rename Version…") {
                    name = version.name ?? ""
                    renaming = true
                    nameFocused = true
                }
                Button("Export Audio…") { model.exportAudio(of: track.id, version: version.id) }
                Button("Show in Finder") {
                    if let url = store.audioURL(for: track.id, version: version.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Divider()
                Button("Delete Version…", role: .destructive, action: onDelete)
                    .disabled(track.versions.count == 1)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func saveName() {
        store.renameVersion(version.id, of: track.id, to: name)
        renaming = false
    }
}

// MARK: - Folder

/// Puts the track directly in a folder (independent of its collections).
private struct FolderChooserPane: View {
    @Environment(AppModel.self) private var model
    let store: LibraryStore
    let trackID: UUID

    @State private var newName = ""

    var body: some View {
        let current = store.folder(ofTrack: trackID)
        ScrollView {
            VStack(spacing: 16) {
                ActionGroup {
                    row(title: "None", depth: 0, systemImage: "tray", selected: current == nil) {
                        store.moveTrack(trackID, toFolder: nil)
                    }
                    ForEach(entries, id: \.folder.id) { entry in
                        RowDivider()
                        row(title: entry.folder.title, depth: entry.depth, systemImage: "folder", selected: current == entry.folder.id) {
                            store.moveTrack(trackID, toFolder: entry.folder.id)
                        }
                    }
                }
                HStack {
                    TextField("New folder", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createFolder)
                    Button("Create", action: createFolder)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("A track can sit in a folder on its own, and also be in any number of collections.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func row(title: String, depth: Int, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 14 + CGFloat(depth) * 18)
            .padding(.trailing, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var entries: [(folder: LibraryFolder, depth: Int)] {
        var result: [(LibraryFolder, Int)] = []
        func visit(_ parent: UUID?, depth: Int) {
            for folder in store.subfolders(of: parent) {
                result.append((folder, depth))
                visit(folder.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    private func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let folder = store.createFolder(title: name)
        store.moveTrack(trackID, toFolder: folder.id)
        newName = ""
    }
}

// MARK: - Building blocks

struct ActionGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 54)
    }
}

struct ActionRowLabel: View {
    let title: String
    let systemImage: String
    var detail: String?
    var isDestructive = false
    var showsChevron = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 15))
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(isDestructive ? Color.red : Color.primary)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.primary.opacity(hovering ? 0.05 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ActionRow: View {
    let title: String
    let systemImage: String
    var detail: String?
    var role: ButtonRole?
    var showsChevron = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ActionRowLabel(title: title, systemImage: systemImage, detail: detail, isDestructive: role == .destructive, showsChevron: showsChevron)
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}
