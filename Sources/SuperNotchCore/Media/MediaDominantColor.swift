import Foundation

// Owner: media. Optional subtle accent colour from the album cover (SPEC §A.5). Pure and tested: the app
// draws the cover into a tiny RGBA8 bitmap (24x24) and hands the bytes to `extract`.

public struct MediaAccentColor: Sendable, Hashable {
    /// 0…1 components (sRGB-ish).
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum MediaDominantColor {
    private static let hueBins = 12
    /// Pixels darker or greyer than this are ignored when looking for a "colour".
    private static let minimumSaturation = 0.18
    private static let minimumBrightness = 0.18
    /// At least this share of the opaque pixels must be colourful, otherwise the cover has no accent
    /// (black-and-white covers keep the neutral white UI).
    private static let minimumColourfulShare = 0.04

    /// Most prominent saturated hue of `rgba` (8 bit, premultiplied or straight alpha, row-major, 4 bytes per
    /// pixel), or nil for near-greyscale / empty / transparent input. The result is normalised so it stays
    /// readable on the notch's black background (saturation 0.4…0.9, brightness 0.7…0.95).
    public static func extract(rgba: [UInt8], width: Int, height: Int) -> MediaAccentColor? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var weights = [Double](repeating: 0, count: hueBins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: hueBins)
        var opaque = 0
        var colourful = 0

        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let alpha = Double(rgba[offset + 3]) / 255
            if alpha < 0.5 { continue }
            opaque += 1
            let r = min(1, Double(rgba[offset]) / 255 / alpha)
            let g = min(1, Double(rgba[offset + 1]) / 255 / alpha)
            let b = min(1, Double(rgba[offset + 2]) / 255 / alpha)
            let (hue, saturation, value) = hsv(r, g, b)
            if saturation < minimumSaturation || value < minimumBrightness { continue }
            colourful += 1
            let weight = saturation * (0.35 + value)
            let bin = min(hueBins - 1, Int(hue * Double(hueBins)))
            weights[bin] += weight
            sums[bin].r += r * weight
            sums[bin].g += g * weight
            sums[bin].b += b * weight
        }

        guard opaque > 0, Double(colourful) / Double(opaque) >= minimumColourfulShare else { return nil }
        var best = 0
        for bin in 1..<hueBins where weights[bin] > weights[best] { best = bin }
        guard weights[best] > 0 else { return nil }

        let r = sums[best].r / weights[best]
        let g = sums[best].g / weights[best]
        let b = sums[best].b / weights[best]
        let (hue, saturation, value) = hsv(r, g, b)
        let (outR, outG, outB) = rgb(hue: hue, saturation: min(max(saturation, 0.4), 0.9), value: min(max(value, 0.7), 0.95))
        return MediaAccentColor(red: outR, green: outG, blue: outB)
    }

    // MARK: HSV

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    static func rgb(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
        let scaled = (hue - hue.rounded(.down)) * 6
        let sector = Int(scaled) % 6
        let fraction = scaled - Double(Int(scaled))
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }
}
