import CodexBridgeShared
import Foundation

public struct MemoSpecStore: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func url(for memoID: MemoID) -> URL {
        root.appending(path: "\(memoID.rawValue).spec.md")
    }

    public func load(memoID: MemoID) -> MemoSpec? {
        let url = url(for: memoID)
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return MemoSpecDocument.parse(text)
    }

    public func save(_ spec: MemoSpec, memoID: MemoID) throws {
        let url = url(for: memoID)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try Data(MemoSpecDocument.serialized(spec).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
}
