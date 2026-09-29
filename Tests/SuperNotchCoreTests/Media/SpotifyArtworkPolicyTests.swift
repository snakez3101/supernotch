// Owner: media. Cover source selection and oEmbed parsing.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("SpotifyArtworkPolicy")
struct SpotifyArtworkPolicyTests {
    func track(id: String = "spotify:track:abc", artwork: String? = nil) -> TrackInfo {
        TrackInfo(id: id, title: "T", artist: "A", album: "B", durationSeconds: 100, artworkURL: artwork)
    }

    @Test func prefersTheAppleScriptURL() throws {
        let source = SpotifyArtworkPolicy.source(
            for: track(artwork: "https://i.scdn.co/image/ab67"), allowOEmbedFallback: true)
        #expect(source == .image(try #require(URL(string: "https://i.scdn.co/image/ab67"))))
    }

    @Test func upgradesHTTPAndRejectsOtherSchemes() {
        #expect(SpotifyArtworkPolicy.normalizedImageURL("http://i.scdn.co/image/x")?.absoluteString == "https://i.scdn.co/image/x")
        #expect(SpotifyArtworkPolicy.normalizedImageURL("file:///etc/passwd") == nil)
        #expect(SpotifyArtworkPolicy.normalizedImageURL("javascript:alert(1)") == nil)
        #expect(SpotifyArtworkPolicy.normalizedImageURL("https://") == nil)
        #expect(SpotifyArtworkPolicy.normalizedImageURL("missing value") == nil)
        #expect(SpotifyArtworkPolicy.normalizedImageURL("  ") == nil)
        #expect(SpotifyArtworkPolicy.normalizedImageURL(nil) == nil)
    }

    @Test func oEmbedFallbackOnlyWhenAllowedAndOnlyForRealTracks() throws {
        #expect(SpotifyArtworkPolicy.source(for: track(), allowOEmbedFallback: false) == nil)

        let source = try #require(SpotifyArtworkPolicy.source(for: track(), allowOEmbedFallback: true))
        guard case .oEmbed(let url) = source else {
            Issue.record("expected an oEmbed source")
            return
        }
        #expect(url.host == "open.spotify.com")
        #expect(url.path == "/oembed")
        #expect(url.absoluteString.contains("open.spotify.com/track/abc"))

        let episode = track(id: "spotify:episode:xyz")
        #expect(SpotifyArtworkPolicy.source(for: episode, allowOEmbedFallback: true) != nil)
        #expect(SpotifyArtworkPolicy.source(for: track(id: "spotify:ad:1"), allowOEmbedFallback: true) == nil)
        #expect(SpotifyArtworkPolicy.source(for: track(id: "spotify:local:A:B:C:1"), allowOEmbedFallback: true) == nil)
    }

    @Test func parsesOEmbedThumbnail() throws {
        let data = try MediaFixtures.data("oembed-track", ext: "json")
        let url = try #require(SpotifyArtworkPolicy.thumbnailURL(fromOEmbed: data))
        #expect(url.scheme == "https")  // upgraded from http
        #expect(url.host == "image-cdn-ak.spotifycdn.com")
        #expect(SpotifyArtworkPolicy.thumbnailURL(fromOEmbed: Data("not json".utf8)) == nil)
        #expect(SpotifyArtworkPolicy.thumbnailURL(fromOEmbed: Data("{}".utf8)) == nil)
        #expect(SpotifyArtworkPolicy.thumbnailURL(fromOEmbed: Data("[1,2]".utf8)) == nil)
    }

    @Test func cacheKeysDistinguishSources() throws {
        let url = try #require(URL(string: "https://i.scdn.co/image/a"))
        #expect(SpotifyArtworkSource.image(url).cacheKey != SpotifyArtworkSource.oEmbed(url).cacheKey)
    }
}
