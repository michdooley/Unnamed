import Foundation

/// Credit for artwork that came from somewhere else (an Unsplash photo).
/// Stored with the collection or track so it can be shown wherever the art is.
public struct ArtworkCredit: Codable, Hashable, Sendable {
    /// Where it came from, e.g. "Unsplash".
    public var source: String
    public var author: String
    public var authorURL: URL?
    /// The photo's own page.
    public var sourceURL: URL?

    public init(source: String, author: String, authorURL: URL?, sourceURL: URL?) {
        self.source = source
        self.author = author
        self.authorURL = authorURL
        self.sourceURL = sourceURL
    }
}

/// A photo from the Unsplash API (only the fields the picker uses).
public struct UnsplashPhoto: Decodable, Identifiable, Hashable, Sendable {
    public struct URLs: Decodable, Hashable, Sendable {
        public let raw: URL
        public let regular: URL
        public let small: URL
        public let thumb: URL
    }

    public struct Links: Decodable, Hashable, Sendable {
        public let html: URL
        /// Must be requested whenever a photo is actually used (API guidelines).
        public let downloadLocation: URL
    }

    public struct User: Decodable, Hashable, Sendable {
        public struct Links: Decodable, Hashable, Sendable {
            public let html: URL
        }

        public let name: String
        public let links: Links
    }

    public let id: String
    public let width: Int
    public let height: Int
    /// The photo's average colour as "#rrggbb", for placeholders.
    public let color: String?
    public let altDescription: String?
    public let urls: URLs
    public let links: Links
    public let user: User

    /// Credit for the photographer and Unsplash, with referral links as the
    /// API guidelines ask.
    public var credit: ArtworkCredit {
        ArtworkCredit(
            source: "Unsplash",
            author: user.name,
            authorURL: UnsplashClient.referral(user.links.html),
            sourceURL: UnsplashClient.referral(links.html)
        )
    }
}

/// A small client for the Unsplash API: browse, search, and fetch a photo
/// for use as artwork. Needs a (free) access key from unsplash.com/developers.
public struct UnsplashClient: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalidKey
        case rateLimited
        case server(status: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidKey: "Unsplash didn't accept the access key. Check it in Settings."
            case .rateLimited: "Unsplash's hourly limit was reached. Try again in a little while."
            case .server(let status): "Unsplash returned an error (\(status))."
            }
        }
    }

    public static let pageSize = 30
    /// Identifies this app in attribution links.
    public static let appName = "unnamed"
    static let api = URL(string: "https://api.unsplash.com")!

    let accessKey: String
    let session: URLSession

    public init(accessKey: String, session: URLSession = .shared) {
        self.accessKey = accessKey
        self.session = session
    }

    /// Popular photos when `query` is empty, otherwise search results.
    public func photos(matching query: String, page: Int) async throws -> (photos: [UnsplashPhoto], hasMore: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let photos: [UnsplashPhoto] = try await get(Self.url("/photos", [
                "page": "\(page)", "per_page": "\(Self.pageSize)", "order_by": "popular",
            ]))
            return (photos, photos.count == Self.pageSize)
        }
        struct Results: Decodable {
            let totalPages: Int
            let results: [UnsplashPhoto]
        }
        let results: Results = try await get(Self.url("/search/photos", [
            "query": trimmed, "page": "\(page)", "per_page": "\(Self.pageSize)", "content_filter": "high",
        ]))
        return (results.results, page < results.totalPages)
    }

    /// Downloads a photo, square-cropped, for use as artwork, and tells
    /// Unsplash it was used (required by their guidelines).
    public func imageData(for photo: UnsplashPhoto, pixelSize: Int = 1400) async throws -> Data {
        var tracking = URLRequest(url: photo.links.downloadLocation)
        authorize(&tracking)
        _ = try? await session.data(for: tracking)

        let image = Self.squareImageURL(photo.urls.raw, pixelSize: pixelSize)
        let (data, response) = try await session.data(from: image)
        try Self.check(response)
        return data
    }

    // MARK: - Helpers

    static func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// Unsplash's image service crops and resizes from the raw URL.
    static func squareImageURL(_ raw: URL, pixelSize: Int) -> URL {
        var components = URLComponents(url: raw, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []).filter { !["w", "h", "fit", "crop", "fm", "q"].contains($0.name) }
        items += [
            URLQueryItem(name: "w", value: "\(pixelSize)"),
            URLQueryItem(name: "h", value: "\(pixelSize)"),
            URLQueryItem(name: "fit", value: "crop"),
            URLQueryItem(name: "crop", value: "entropy"),
            URLQueryItem(name: "fm", value: "jpg"),
            URLQueryItem(name: "q", value: "85"),
        ]
        components.queryItems = items
        return components.url!
    }

    /// Adds the referral parameters Unsplash asks attribution links to carry.
    public static func referral(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "utm_source", value: appName),
            URLQueryItem(name: "utm_medium", value: "referral"),
        ]
        return components.url ?? url
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw Failure.invalidKey
        case 403 where http.value(forHTTPHeaderField: "X-Ratelimit-Remaining") == "0": throw Failure.rateLimited
        default: throw Failure.server(status: http.statusCode)
        }
    }

    static func decodePhotos(_ data: Data) throws -> [UnsplashPhoto] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([UnsplashPhoto].self, from: data)
    }
}
