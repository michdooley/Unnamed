import CoreGraphics
import Foundation

/// Moodboards: a collection's songs laid out as threads on a canvas, with
/// pictures, videos, text and drawings around them.
public extension LibraryStore {
    /// A collection's moodboard (an empty one if it hasn't been started).
    func board(for collectionID: UUID) -> Moodboard {
        boards[collectionID] ?? Moodboard()
    }

    /// Adds or updates items, e.g. at the end of a drag.
    func saveBoardItems(_ items: [BoardItem], in collectionID: UUID) {
        guard collections[collectionID] != nil, !items.isEmpty else { return }
        var board = board(for: collectionID)
        for item in items {
            var item = item
            item.updatedAt = .libraryNow
            board.items[item.id] = item
            let saved = item
            let url = layout.boardItemFile(collectionID, item: item.id)
            enqueue { disk in try await disk.writeJSON(saved, to: url) }
        }
        boards[collectionID] = board
    }

    /// Takes items off a board. Their pictures and videos stay on disk for a
    /// day (so Undo, and other devices still syncing, can find them).
    func removeBoardItems(_ ids: [UUID], from collectionID: UUID) {
        guard var board = boards[collectionID] else { return }
        for id in ids where board.items.removeValue(forKey: id) != nil {
            let url = layout.boardItemFile(collectionID, item: id)
            enqueue { disk in try await disk.remove(url) }
        }
        boards[collectionID] = board
    }

    func setBoardBackground(_ hex: String, for collectionID: UUID) {
        guard collections[collectionID] != nil else { return }
        var board = board(for: collectionID)
        guard board.settings.background != hex else { return }
        board.settings.background = hex
        board.settings.updatedAt = .libraryNow
        boards[collectionID] = board
        let settings = board.settings
        let url = layout.boardFile(collectionID)
        enqueue { disk in try await disk.writeJSON(settings, to: url) }
    }

    /// Board units for the long side of a newly placed picture or video.
    static var boardMediaSide: Double { 360 }

    /// Shrinks pictures and videos (see `BoardMedia`) and puts them on a
    /// board centred on `center`, each one a little further along.
    @discardableResult
    func addBoardMedia(from urls: [URL], to collectionID: UUID, centeredAt center: BoardPoint) async -> [BoardItem] {
        var added: [BoardItem] = []
        var spot = center
        for url in urls where BoardMedia.isImage(url) || BoardMedia.isVideo(url) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let item = await addBoardMedium(at: url, to: collectionID, centeredAt: spot) {
                added.append(item)
                spot = spot + BoardPoint(40, 40)
            }
        }
        return added
    }

    /// Puts a pasted or dropped picture (as data) on a board.
    @discardableResult
    func addBoardImage(data: Data, to collectionID: UUID, centeredAt center: BoardPoint) async -> BoardItem? {
        do {
            let encoded = try await Task.detached(priority: .userInitiated) { try BoardMedia.encodeImage(data: data) }.value
            return placeImage(encoded, in: collectionID, centeredAt: center)
        } catch {
            report(error, title: "Couldn't add the picture")
            return nil
        }
    }

    private func addBoardMedium(at url: URL, to collectionID: UUID, centeredAt center: BoardPoint) async -> BoardItem? {
        guard collections[collectionID] != nil else { return nil }
        do {
            if BoardMedia.isVideo(url) {
                let id = UUID()
                let temporary = FileManager.default.temporaryDirectory.appending(path: "board-\(id.uuidString).mov")
                let size = try await BoardMedia.encodeVideo(at: url, to: temporary)
                guard collections[collectionID] != nil else {
                    try? FileManager.default.removeItem(at: temporary)
                    return nil
                }
                let file = "\(id.uuidString).mov"
                let destination = layout.boardMediaURL(collectionID: collectionID, file: file)
                enqueue { disk in try await disk.moveIntoPlace(temporary, to: destination) }
                return place(.video, id: id, file: file, pixelSize: size, in: collectionID, centeredAt: center)
            }
            let encoded = try await Task.detached(priority: .userInitiated) { try BoardMedia.encodeImage(at: url) }.value
            guard collections[collectionID] != nil else { return nil }
            return placeImage(encoded, in: collectionID, centeredAt: center)
        } catch {
            report(error, title: "Couldn't add “\(url.lastPathComponent)” to the moodboard")
            return nil
        }
    }

    private func placeImage(_ encoded: BoardMedia.EncodedImage, in collectionID: UUID, centeredAt center: BoardPoint) -> BoardItem? {
        guard collections[collectionID] != nil else { return nil }
        let id = UUID()
        let file = "\(id.uuidString).\(encoded.fileExtension)"
        let url = layout.boardMediaURL(collectionID: collectionID, file: file)
        let data = encoded.data
        enqueue { disk in try await disk.writeData(data, to: url) }
        return place(.image, id: id, file: file, pixelSize: encoded.pixelSize, in: collectionID, centeredAt: center)
    }

    private func place(_ kind: BoardItem.Kind, id: UUID, file: String, pixelSize: CGSize, in collectionID: UUID, centeredAt center: BoardPoint) -> BoardItem {
        let side = Self.boardMediaSide
        let aspect = pixelSize.width > 0 && pixelSize.height > 0 ? Double(pixelSize.width / pixelSize.height) : 1
        let width = aspect >= 1 ? side : side * aspect
        let height = aspect >= 1 ? side / aspect : side
        var item = BoardItem(id: id, kind: kind, position: center - BoardPoint(width / 2, height / 2), z: board(for: collectionID).topZ + 1)
        item.file = file
        item.width = width
        item.height = height
        saveBoardItems([item], in: collectionID)
        return item
    }

    /// Where a board picture or video lives (it may still be in iCloud).
    func boardMediaURL(_ item: BoardItem, in collectionID: UUID) -> URL? {
        item.file.map { layout.boardMediaURL(collectionID: collectionID, file: $0) }
    }

    /// A board picture or video, downloaded from iCloud first if need be.
    /// Nil if it isn't there (yet).
    func readyBoardMedia(_ item: BoardItem, in collectionID: UUID) async -> URL? {
        guard let url = boardMediaURL(item, in: collectionID) else { return nil }
        var status = await disk.cloudStatus(of: url)
        if status.isPlayableWithoutDownload { return url }
        guard isInCloud else { return nil }
        if status != .missing { try? await disk.startDownloading(url) }
        for _ in 0..<150 {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return nil   // no longer wanted (scrolled away, say)
            }
            status = await disk.cloudStatus(of: url)
            if status.isPlayableWithoutDownload { return url }
            if status == .notDownloaded { try? await disk.startDownloading(url) }
        }
        return nil
    }

    /// Deletes pictures and videos that no item on the board has used for a
    /// day (counted from when this device first saw them unused). Which files
    /// are in use is read straight from the item files, so items this version
    /// can't read still count, and nothing is deleted while any item file
    /// can't be read (still downloading, say).
    func tidyBoardMedia(of collectionID: UUID, now: Date = Date()) async {
        guard let used = await disk.boardMediaInUse(of: collectionID) else { return }
        let files = await disk.boardMediaFiles(of: collectionID)
        let key = "moodboard.unusedSince.\(collectionID.uuidString)"
        let seen = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] ?? [:]
        var stillWaiting: [String: Date] = [:]
        for url in files where !used.contains(url.lastPathComponent) {
            let since = seen[url.lastPathComponent] ?? now
            if now.timeIntervalSince(since) > 24 * 3600 {
                enqueue { disk in try await disk.remove(url) }
            } else {
                stillWaiting[url.lastPathComponent] = since
            }
        }
        UserDefaults.standard.set(stillWaiting, forKey: key)
    }
}
