import SwiftUI
import UnnamedKit

/// What an artwork picker is choosing art for.
enum ArtworkTarget: Identifiable, Hashable {
    case collection(UUID)
    case track(UUID)

    var id: UUID {
        switch self {
        case .collection(let id), .track(let id): id
        }
    }
}

/// Browse or search Unsplash and use a photo as cover art. The photographer
/// is credited with the artwork, as Unsplash's guidelines ask.
struct UnsplashPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: ArtworkTarget

    @State private var query = ""
    @State private var photos: [UnsplashPhoto] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var problem: String?
    @State private var applying: String?
    @State private var keyDraft = ""
    /// Bumped by every new search, so late results from an older one are dropped.
    @State private var generation = 0
    @State private var nextPageTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                Text("Unsplash")
                    .font(.headline)
                if !model.unsplashKey.isEmpty {
                    TextField("Search photos", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // Once a photo is being saved, let it finish.
                    .disabled(applying != nil)
            }
            .padding(16)
            Divider()

            if model.unsplashKey.isEmpty {
                keySetup
            } else {
                results
                Divider()
                Text(.init("Photos from [Unsplash](https://unsplash.com/?utm_source=\(UnsplashClient.appName)&utm_medium=referral). The photographer is credited alongside the art."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 760, height: 580)
        .task(id: "\(query)|\(model.unsplashKey)") {
            guard !model.unsplashKey.isEmpty else { return }
            // Wait for a pause in typing before searching.
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350))
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .onAppear { searchFocused = true }
    }

    private var results: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(photos) { photo in
                    PhotoTile(photo: photo, isApplying: applying == photo.id)
                        .onTapGesture { Task { await use(photo) } }
                        .onAppear {
                            if photo.id == photos.last?.id, hasMore, !loading {
                                nextPageTask = Task { await load(reset: false) }
                            }
                        }
                }
            }
            .padding(16)
            if loading {
                ProgressView().padding(.bottom, 16)
            } else if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else if photos.isEmpty {
                Text("No photos found.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
        .disabled(applying != nil)
    }

    /// Unsplash needs a free access key, which only its owner can create.
    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Unsplash")
                .font(.system(size: 20, weight: .semibold))
            Text("Unsplash's API needs a free Access Key. Create an app at [unsplash.com/developers](https://unsplash.com/developers), which takes a minute, then paste its Access Key here. It's stored on this Mac only.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Access Key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(saveKey)
                Button("Connect", action: saveKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveKey() {
        model.unsplashAccessKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load(reset: Bool) async {
        if reset {
            generation += 1
            nextPageTask?.cancel()
        }
        let started = generation
        let client = UnsplashClient(accessKey: model.unsplashKey)
        let nextPage = reset ? 1 : page + 1
        loading = true
        problem = nil
        defer { if started == generation { loading = false } }
        do {
            let result = try await client.photos(matching: query, page: nextPage)
            // A newer search started meanwhile: these results are stale.
            guard !Task.isCancelled, started == generation else { return }
            photos = reset ? result.photos : photos + result.photos.filter { new in !photos.contains { $0.id == new.id } }
            page = nextPage
            hasMore = result.hasMore
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            guard !cancelled, started == generation else { return }
            if reset { photos = [] }
            problem = error.localizedDescription
        }
    }

    private func use(_ photo: UnsplashPhoto) async {
        guard applying == nil, let store = model.store else { return }
        applying = photo.id
        defer { applying = nil }
        do {
            let data = try await UnsplashClient(accessKey: model.unsplashKey).imageData(for: photo)
            switch target {
            case .collection(let id):
                await store.setArtwork(forCollection: id, from: .data(data), credit: photo.credit)
            case .track(let id):
                await store.setArtwork(forTrack: id, from: .data(data), credit: photo.credit)
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct PhotoTile: View {
    let photo: UnsplashPhoto
    let isApplying: Bool
    @State private var hovering = false

    var body: some View {
        Color(hexString: photo.color)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: photo.urls.small) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .overlay(alignment: .bottomLeading) {
                if hovering {
                    Text(photo.user.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                if isApplying {
                    ZStack {
                        Color.black.opacity(0.35)
                        ProgressView().tint(.white)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: hovering ? 2 : 0)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(photo.altDescription ?? "Photo by \(photo.user.name)")
    }
}

/// "Photo by Jane Doe on Unsplash", with links.
struct ArtworkCreditLine: View {
    let credit: ArtworkCredit

    var body: some View {
        let author = credit.authorURL.map { "[\(escaped(credit.author))](\($0.absoluteString))" } ?? escaped(credit.author)
        let source = credit.sourceURL.map { "[\(credit.source)](\($0.absoluteString))" } ?? credit.source
        Text(.init("Photo by \(author) on \(source)"))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .tint(.secondary)
            .lineLimit(1)
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }
}

/// The choices behind "Add Cover Art": a file, or a photo from Unsplash.
struct ArtworkChoices: View {
    @Environment(AppModel.self) private var model
    let target: ArtworkTarget
    var hasArtwork: Bool
    var onChoose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PopoverRow(title: "Upload Image…", systemImage: "photo.badge.plus") {
                onChoose()
                model.uploadArtwork(for: target)
            }
            PopoverRow(title: "Browse Unsplash…", systemImage: "photo.on.rectangle.angled") {
                onChoose()
                model.unsplashTarget = target
            }
            if hasArtwork {
                Divider().padding(.vertical, 4)
                PopoverRow(title: "Remove Artwork", systemImage: "xmark.circle") {
                    onChoose()
                    model.removeArtwork(for: target)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 220)
        .fixedSize()
    }
}

extension Color {
    /// "#rrggbb", or gray when missing.
    init(hexString: String?) {
        let digits = (hexString ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(digits, radix: 16) ?? 0x808080)
    }
}
