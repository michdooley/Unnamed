import Foundation
import Testing
@testable import UnnamedKit

/// Answers requests from a table instead of the network, and records them.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: Data, headers: [String: String])] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        let key = url.host! + url.path
        let stub = Self.responses[key] ?? (404, Data(), [:])
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

let photoJSON = """
{
  "id": "abc123", "width": 4000, "height": 3000, "color": "#26402a",
  "alt_description": "green hills at dusk",
  "urls": {
    "raw": "https://images.unsplash.com/photo-1?ixid=xyz",
    "full": "https://images.unsplash.com/photo-1?q=85",
    "regular": "https://images.unsplash.com/photo-1?w=1080",
    "small": "https://images.unsplash.com/photo-1?w=400",
    "thumb": "https://images.unsplash.com/photo-1?w=200"
  },
  "links": {
    "self": "https://api.unsplash.com/photos/abc123",
    "html": "https://unsplash.com/photos/abc123",
    "download": "https://unsplash.com/photos/abc123/download",
    "download_location": "https://api.unsplash.com/photos/abc123/download?ixid=xyz"
  },
  "user": { "id": "u1", "username": "jane", "name": "Jane Doe", "links": { "html": "https://unsplash.com/@jane" } }
}
"""

@Suite(.serialized)
struct UnsplashTests {
    init() {
        StubProtocol.responses = [:]
        StubProtocol.requests = []
    }

    @Test func decodesPhotosAndBuildsCredit() throws {
        let photos = try UnsplashClient.decodePhotos(Data("[\(photoJSON)]".utf8))
        let photo = try #require(photos.first)
        #expect(photo.user.name == "Jane Doe")
        #expect(photo.altDescription == "green hills at dusk")
        #expect(photo.links.downloadLocation.absoluteString.hasSuffix("/download?ixid=xyz"))
        #expect(photo.credit.author == "Jane Doe")
        #expect(photo.credit.authorURL?.absoluteString == "https://unsplash.com/@jane?utm_source=unnamed&utm_medium=referral")
    }

    @Test func searchesWithTheAccessKeyAndPages() async throws {
        StubProtocol.responses["api.unsplash.com/search/photos"] = (200, Data(#"{"total":31,"total_pages":2,"results":[\#(photoJSON)]}"#.utf8), [:])
        let client = UnsplashClient(accessKey: "KEY", session: StubProtocol.session())

        let result = try await client.photos(matching: " hills ", page: 1)

        #expect(result.photos.map(\.id) == ["abc123"])
        #expect(result.hasMore)
        let request = try #require(StubProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Client-ID KEY")
        #expect(request.url?.query?.contains("query=hills") == true)
    }

    @Test func usingAPhotoRegistersTheDownloadAndFetchesASquareCrop() async throws {
        let photo = try #require(try UnsplashClient.decodePhotos(Data("[\(photoJSON)]".utf8)).first)
        StubProtocol.responses["api.unsplash.com/photos/abc123/download"] = (200, Data("{}".utf8), [:])
        StubProtocol.responses["images.unsplash.com/photo-1"] = (200, Data([0xFF, 0xD8, 0xFF]), [:])
        let client = UnsplashClient(accessKey: "KEY", session: StubProtocol.session())

        let data = try await client.imageData(for: photo, pixelSize: 1400)

        #expect(data == Data([0xFF, 0xD8, 0xFF]))
        let urls = StubProtocol.requests.compactMap(\.url?.absoluteString)
        #expect(urls.first?.contains("/photos/abc123/download") == true)
        let image = try #require(urls.last)
        #expect(image.contains("w=1400") && image.contains("h=1400") && image.contains("fit=crop") && image.contains("ixid=xyz"))
    }

    @Test func reportsABadKey() async throws {
        StubProtocol.responses["api.unsplash.com/photos"] = (401, Data(), [:])
        let client = UnsplashClient(accessKey: "nope", session: StubProtocol.session())
        await #expect(throws: UnsplashClient.Failure.invalidKey) {
            _ = try await client.photos(matching: "", page: 1)
        }
    }

    @Test @MainActor func artworkCreditIsSavedWithTheCover() async throws {
        let store = LibraryStore(root: try TestAudio.temporaryDirectory().appending(path: "Library"))
        await store.load()
        let collection = store.createCollection(title: "Art")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let credit = ArtworkCredit(source: "Unsplash", author: "Jane Doe", authorURL: URL(string: "https://unsplash.com/@jane"), sourceURL: nil)

        await store.setArtwork(forCollection: collection.id, from: .data(png), credit: credit)
        #expect(store.collections[collection.id]?.artworkCredit == credit)
        await store.flush()
        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        #expect(reopened.collections[collection.id]?.artworkCredit == credit)

        // Replacing or removing the art drops the credit.
        await store.setArtwork(forCollection: collection.id, from: .data(png))
        #expect(store.collections[collection.id]?.artworkCredit == nil)
    }
}
