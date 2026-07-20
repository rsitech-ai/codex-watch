@testable import CodexBridgeService
import CodexBridgeShared
import Foundation
import Testing

@Test func committedAudioAssetRejectsPathReplacementAfterInspection() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "committed-audio-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let url = root.appending(path: "audio.m4a")
    let original = Data("committed-audio".utf8)
    try original.write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
    )
    let asset = try CommittedAudioAsset(
        url: url,
        expectedSHA256: AudioDigest.hex(original)
    )

    try FileManager.default.removeItem(at: url)
    try Data("replacement".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
    )

    #expect(throws: CommittedAudioAssetError.identityChanged) {
        try asset.validate()
    }
}
