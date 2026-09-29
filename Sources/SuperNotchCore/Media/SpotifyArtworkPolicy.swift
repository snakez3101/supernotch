import Foundation

// Owner: media. Where the cover of the current track comes from (SPEC §A.5).
// Primary: the `artwork url` from AppleScript (https://i.scdn.co/image/..., 640 px).
// Fallback without any permission: Spotify's public oEmbed endpoint returns a `thumbnail_url` for tracks
// and episodes. Ads and local files have no cover.

public enum SpotifyArtworkSource: Sendable, Hashable {
    /// Direct image URL.
    case image(URL)
    /// oEmbed JSON URL; the image is `thumbnail_url` inside it.
    case oEmbed(URL)

    /// Stable cache key.
    public var cacheKey: String {
        switch self {
        case .image(let url): return "img:" + url.absoluteString
        case .oEmbed(let url): return "oembed:" + url.absoluteString
        }
    }
}

public enum SpotifyArtworkPolicy {
    public static let oEmbedEndpoint = "https://open.spotify.com/oembed"

    /// Picks the artwork source for a track. The oEmbed fallback is only used when `allowOEmbedFallback`
    /// (the caller sets it once AppleScript has had its chance to provide a URL, or when AppleScript is not
    /// permitted at all), so a normal track change costs exactly one image request.
    public static func source(for track: TrackInfo, allowOEmbedFallback: Bool) -> SpotifyArtworkSource? {
        if let url = normalizedImageURL(track.artworkURL) { return .image(url) }
        guard allowOEmbedFallback, !track.isAd, !track.isLocal, let open = track.openURL,
            let url = oEmbedURL(forOpenURL: open)
        else { return nil }
        return .oEmbed(url)
    }

    /// Accepts only http(s) URLs with a host; upgrades http to https.
    public static func normalizedImageURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = "https"
        return components.url
    }

    public static func oEmbedURL(forOpenURL openURL: String) -> URL? {
        guard var components = URLComponents(string: oEmbedEndpoint) else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: openURL)]
        return components.url
    }

    /// `thumbnail_url` of an oEmbed response, validated like any other image URL.
    public static func thumbnailURL(fromOEmbed data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return normalizedImageURL(object["thumbnail_url"] as? String)
    }
}
