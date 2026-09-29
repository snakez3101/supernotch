// Owner: media. Album-art accent extraction on synthetic bitmaps.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("MediaDominantColor")
struct MediaDominantColorTests {
    /// width x height bitmap from a per-pixel closure returning (r, g, b, a) in 0…255.
    func bitmap(
        _ width: Int = 8, _ height: Int = 8, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                bytes.append(contentsOf: [r, g, b, a])
            }
        }
        return bytes
    }

    @Test func solidRedIsRed() throws {
        let color = try #require(
            MediaDominantColor.extract(rgba: bitmap { _, _ in (220, 20, 30, 255) }, width: 8, height: 8))
        #expect(color.red > 0.8)
        #expect(color.green < 0.5)
        #expect(color.blue < 0.5)
    }

    @Test func majorityHueWins() throws {
        // 3/4 blue, 1/4 red.
        let pixels = bitmap { x, _ in x < 6 ? (20, 40, 230, 255) : (230, 30, 30, 255) }
        let color = try #require(MediaDominantColor.extract(rgba: pixels, width: 8, height: 8))
        #expect(color.blue > color.red)
        #expect(color.blue > color.green)
    }

    @Test func greyscaleHasNoAccent() {
        let grey = bitmap { x, _ in
            let v = UInt8(x * 30)
            return (v, v, v, 255)
        }
        #expect(MediaDominantColor.extract(rgba: grey, width: 8, height: 8) == nil)
    }

    @Test func nearBlackAndTransparentHaveNoAccent() {
        #expect(MediaDominantColor.extract(rgba: bitmap { _, _ in (10, 0, 0, 255) }, width: 8, height: 8) == nil)
        #expect(MediaDominantColor.extract(rgba: bitmap { _, _ in (255, 0, 0, 0) }, width: 8, height: 8) == nil)
    }

    @Test func tinyColourfulSpecklesAreIgnored() {
        // 1 saturated pixel in 64 (1.6 %) on a grey cover.
        let pixels = bitmap { x, y in x == 0 && y == 0 ? (250, 10, 10, 255) : (120, 120, 120, 255) }
        #expect(MediaDominantColor.extract(rgba: pixels, width: 8, height: 8) == nil)
    }

    @Test func darkCoverIsBrightenedForTheBlackBackground() throws {
        let color = try #require(
            MediaDominantColor.extract(rgba: bitmap { _, _ in (60, 20, 20, 255) }, width: 8, height: 8))
        #expect(max(color.red, color.green, color.blue) >= 0.69)
    }

    @Test func invalidInputIsRejected() {
        #expect(MediaDominantColor.extract(rgba: [], width: 0, height: 0) == nil)
        #expect(MediaDominantColor.extract(rgba: [1, 2, 3], width: 2, height: 2) == nil)
        #expect(MediaDominantColor.extract(rgba: [255, 0, 0, 255], width: -1, height: 1) == nil)
    }

    @Test func premultipliedAlphaIsUndone() throws {
        // 50 % transparent pure red, premultiplied: (127, 0, 0, 128).
        let color = try #require(
            MediaDominantColor.extract(rgba: bitmap { _, _ in (127, 0, 0, 128) }, width: 4, height: 4))
        #expect(color.red > 0.8)
    }
}
