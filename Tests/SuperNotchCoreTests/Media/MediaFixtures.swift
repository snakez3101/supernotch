// Owner: media. Fixture loading for the media tests (SPEC §G.1: Bundle.module + Fixtures/<stream>/).
import Foundation

struct MediaFixtureError: Error, CustomStringConvertible {
    let name: String
    var description: String { "Missing media fixture: \(name)" }
}

enum MediaFixtures {
    /// The separator is written as `<US>` in the fixture files so they stay readable in editors.
    static let separatorPlaceholder = "<US>"

    static func data(_ name: String, ext: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: "Fixtures/media")
        else { throw MediaFixtureError(name: "\(name).\(ext)") }
        return try Data(contentsOf: url)
    }

    /// Raw AppleScript output with `<US>` replaced by U+001F.
    static func status(_ name: String) throws -> String {
        let text = String(decoding: try data(name, ext: "txt"), as: UTF8.self)
        return text.replacingOccurrences(of: separatorPlaceholder, with: "\u{1F}")
    }

    static func json(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try data(name, ext: "json"))
        guard let dictionary = object as? [String: Any] else { throw MediaFixtureError(name: name) }
        return dictionary
    }

    /// A notification `userInfo` as Foundation would deliver it.
    static func userInfo(_ name: String) throws -> [AnyHashable: Any] {
        var result: [AnyHashable: Any] = [:]
        for (key, value) in try json(name) { result[key] = value }
        return result
    }
}
