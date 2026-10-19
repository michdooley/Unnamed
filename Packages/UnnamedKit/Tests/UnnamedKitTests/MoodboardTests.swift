import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UnnamedKit

@MainActor
struct MoodboardTests {
    private func makeLibrary() async throws -> (LibraryStore, TrackCollection, [UUID], URL) {
        let scratch = try TestAudio.temporaryDirectory()
        let urls = try (1...2).map { try TestAudio.makeWAV(named: "t\($0)", seconds: 0.4, in: scratch) }
        let store = LibraryStore(root: scratch.appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "Concept Album")
        let ids = await store.importAudio(from: urls, into: collection.id)
        return (store, collection, ids, scratch)
    }

    @Test func itemsRoundTripThroughJSON() throws {
        var track = BoardItem.track(UUID(), at: BoardPoint(120.5, -40), duration: 180, z: 2)
        track.thread = [.zero, BoardPoint(300, 80), BoardPoint(620, -20)]
        var text = BoardItem(kind: .text, position: BoardPoint(10, 10))
        text.text = "Side A: dusk"
        text.fontSize = 40
        text.width = 320
        var drawing = BoardItem(kind: .drawing, position: BoardPoint(0, 0))
        drawing.points = [.zero, BoardPoint(5, 5), BoardPoint(12, 3)]
        drawing.color = "#FFD60A"
        drawing.lineWidth = 4

        for item in [track, text, drawing] {
            let data = try LibraryJSON.encoder().encode(item)
            let decoded = try LibraryJSON.decoder().decode(BoardItem.self, from: data)
            #expect(decoded == item)
        }
        let json = String(decoding: try LibraryJSON.encoder().encode(track), as: UTF8.self)
        #expect(json.contains("\"type\" : \"track\""))
        #expect(json.contains("[\n    300,\n    80\n  ]") || json.contains("300"))
    }

    @Test func aNewThreadIsAStraightLineAsLongAsTheSong() {
        let short = BoardItem.track(UUID(), at: .zero, duration: 10)
        let long = BoardItem.track(UUID(), at: .zero, duration: 120)
        let huge = BoardItem.track(UUID(), at: .zero, duration: 3600)
        #expect(short.thread?.last == BoardPoint(BoardItem.threadLengthRange.lowerBound, 0))
        #expect(long.thread?.last == BoardPoint(600, 0))
        #expect(huge.thread?.last == BoardPoint(BoardItem.threadLengthRange.upperBound, 0))
    }

    @Test func boardsSurviveAReload() async throws {
        let (store, collection, ids, scratch) = try await makeLibrary()
        let placed = BoardItem.track(ids[0], at: BoardPoint(0, 0), duration: 0.4)
        var note = BoardItem(kind: .text, position: BoardPoint(50, -120), z: 1)
        note.text = "the drive home"
        store.saveBoardItems([placed, note], in: collection.id)
        store.setBoardBackground("#F4EFE6", for: collection.id)
        await store.flush()

        let reopened = LibraryStore(root: scratch.appending(path: "Library"))
        await reopened.load()
        let board = reopened.board(for: collection.id)
        #expect(board.settings.background == "#F4EFE6")
        #expect(board.items.count == 2)
        #expect(board.placement(of: ids[0])?.thread == placed.thread)
        #expect(board.items[note.id]?.text == "the drive home")

        reopened.removeBoardItems([note.id], from: collection.id)
        await reopened.flush()
        let again = LibraryStore(root: scratch.appending(path: "Library"))
        await again.load()
        #expect(again.board(for: collection.id).items.keys.sorted { $0.uuidString < $1.uuidString } == [placed.id])
    }

    @Test func collectionsWithoutABoardDontGetOne() async throws {
        let (store, collection, _, _) = try await makeLibrary()
        await store.reload()
        #expect(store.boards[collection.id] == nil)
        #expect(store.board(for: collection.id).items.isEmpty)
    }

    @Test func aThreadPassesThroughItsKnots() {
        let knots = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 120), CGPoint(x: 400, y: -60), CGPoint(x: 700, y: 30)]
        let path = ThreadPath(knots: knots)
        #expect(path.knotIndices.count == knots.count)
        for (knot, index) in zip(knots, path.knotIndices) {
            #expect(hypot(path.points[index].x - knot.x, path.points[index].y - knot.y) < 0.001)
        }
        #expect(path.length > 700)
    }

    @Test func aStraightThreadMapsTimeEvenly() {
        let path = ThreadPath(knots: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)])
        #expect(abs(path.length - 400) < 0.01)
        let middle = path.sample(atFraction: 0.5)
        #expect(abs(middle.point.x - 200) < 0.5)
        #expect(abs(middle.point.y) < 0.01)
        #expect(abs(middle.tangent.dx - 1) < 0.001)
    }

    @Test func partOfAThreadEndsExactlyThere() {
        let path = ThreadPath(knots: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)])
        let half = path.prefix(toLength: 200)
        #expect(abs((half.last?.x ?? 0) - 200) < 0.01)
        #expect(half.first == CGPoint(x: 0, y: 0))
        #expect(path.prefix(toLength: 10_000).count == path.points.count)
    }

    @Test func longSpansAreSampledFinely() {
        let path = ThreadPath(knots: [CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 300), CGPoint(x: 1200, y: 0)])
        let gaps = zip(path.points, path.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect(gaps.max()! < 12)
    }

    @Test func grabbingAThreadFindsWhereANewKnotGoes() {
        let path = ThreadPath(knots: [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 600, y: 0)])
        let hit = path.nearest(to: CGPoint(x: 450, y: 12))
        #expect(abs(hit.distance - 12) < 0.5)
        #expect(abs(hit.fraction - 0.75) < 0.01)
        #expect(hit.insertIndex == 2)
        #expect(path.nearest(to: CGPoint(x: 100, y: -5)).insertIndex == 1)
    }

    @Test func picturesAreShrunkAndCompressed() throws {
        let scratch = try TestAudio.temporaryDirectory()
        let url = scratch.appending(path: "huge.png")
        try Self.makePNG(width: 4000, height: 2400, at: url)
        let encoded = try BoardMedia.encodeImage(at: url)
        #expect(max(encoded.pixelSize.width, encoded.pixelSize.height) == CGFloat(BoardMedia.maxImagePixels))
        #expect(["heic", "jpg"].contains(encoded.fileExtension))
        let original = try Data(contentsOf: url)
        #expect(encoded.data.count < original.count)
    }

    @Test func picturesGoOnTheBoardAtTheirShape() async throws {
        let (store, collection, _, scratch) = try await makeLibrary()
        let url = scratch.appending(path: "wide.png")
        try Self.makePNG(width: 800, height: 400, at: url)
        let added = await store.addBoardMedia(from: [url], to: collection.id, centeredAt: BoardPoint(0, 0))
        await store.flush()
        let item = try #require(added.first)
        #expect(item.kind == .image)
        #expect(item.width == LibraryStore.boardMediaSide)
        #expect(item.height == LibraryStore.boardMediaSide / 2)
        #expect(item.position == BoardPoint(-item.width! / 2, -item.height! / 2))
        let file = try #require(store.boardMediaURL(item, in: collection.id))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func videosAreReencoded() async throws {
        let scratch = try TestAudio.temporaryDirectory()
        let source = scratch.appending(path: "clip.mov")
        try await Self.makeVideo(width: 320, height: 240, frames: 20, at: source)
        let destination = scratch.appending(path: "out.mov")
        let size = try await BoardMedia.encodeVideo(at: source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(size.width > 0 && size.height > 0)
        #expect(abs(size.width / size.height - 320.0 / 240.0) < 0.05)
    }

    @Test func tidyingKeepsMediaInUseAndWaitsADay() async throws {
        let (store, collection, _, scratch) = try await makeLibrary()
        let url = scratch.appending(path: "pic.png")
        try Self.makePNG(width: 300, height: 200, at: url)
        let kept = try #require(await store.addBoardMedia(from: [url], to: collection.id, centeredAt: .zero).first)
        let removed = try #require(await store.addBoardMedia(from: [url], to: collection.id, centeredAt: .zero).first)
        await store.flush()
        // An item of a type this version doesn't know still owns its file.
        let mystery = try #require(store.boardMediaURL(removed, in: collection.id)).deletingLastPathComponent().appending(path: "future.bin")
        try Data([1, 2, 3]).write(to: mystery)
        let futureItem = store.layout.boardItemFile(collection.id, item: UUID())
        try Data(#"{"type": "hologram", "x": 0, "y": 0, "file": "future.bin"}"#.utf8).write(to: futureItem)
        store.removeBoardItems([removed.id], from: collection.id)
        await store.flush()

        let start = Date()
        await store.tidyBoardMedia(of: collection.id, now: start)
        await store.flush()
        let gone = try #require(store.boardMediaURL(removed, in: collection.id))
        #expect(FileManager.default.fileExists(atPath: gone.path), "kept for a day after it was last used")

        await store.tidyBoardMedia(of: collection.id, now: start.addingTimeInterval(25 * 3600))
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        #expect(FileManager.default.fileExists(atPath: try #require(store.boardMediaURL(kept, in: collection.id)).path))
        #expect(FileManager.default.fileExists(atPath: mystery.path))
    }

    @Test func aJourneyPlaysInOrderEvenWithShuffleOn() {
        var queue = PlaybackQueue()
        queue.setShuffle(true)
        let ids = (0..<8).map { _ in UUID() }
        queue.load(ids, startAt: ids[0], inOrder: true)
        #expect(queue.order == ids)
        #expect(queue.current == ids[0])
    }

    // MARK: - Fixtures

    static func makePNG(width: Int, height: Int, at url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<12 {
            context.setFillColor(CGColor(red: Double(i) / 12, green: 0.4, blue: 1 - Double(i) / 12, alpha: 1))
            context.fill(CGRect(x: i * width / 12, y: 0, width: width / 12 + 1, height: height))
        }
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func makeVideo(width: Int, height: Int, frames: Int, at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * stride + x * 4
                    p[0] = UInt8((x + frame * 8) % 256)
                    p[1] = UInt8(y % 256)
                    p[2] = 128
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
