import AVFAudio
import CodexBridgeShared
import Darwin
import Foundation

enum WatchPlaybackState: Equatable {
    case stopped
    case playing(MemoID)
    case failed(MemoID)
}

@MainActor
protocol WatchAudioPlaying: AnyObject {
    var state: WatchPlaybackState { get }
    func play(memoID: MemoID, url: URL) throws
    func stop()
}

enum WatchAudioPlayerError: Error {
    case couldNotPrepare
    case couldNotStart
}

enum WatchPlaybackFileLeaseError: Error, Equatable {
    case invalidFile
    case identityDrift
}

private final class WatchPlaybackFileLease {
    let fileURL: URL

    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private let owner: uid_t
    private let byteCount: off_t

    init(fileURL: URL) throws {
        guard fileURL.isFileURL else {
            throw WatchPlaybackFileLeaseError.invalidFile
        }
        var pathMetadata = stat()
        guard lstat(fileURL.path, &pathMetadata) == 0,
              Self.isPrivateRegularFile(pathMetadata)
        else { throw WatchPlaybackFileLeaseError.invalidFile }

        let openedDescriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard openedDescriptor >= 0 else {
            throw WatchPlaybackFileLeaseError.invalidFile
        }
        var openedMetadata = stat()
        guard fstat(openedDescriptor, &openedMetadata) == 0,
              Self.isPrivateRegularFile(openedMetadata),
              openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino
        else {
            Darwin.close(openedDescriptor)
            throw WatchPlaybackFileLeaseError.invalidFile
        }

        self.fileURL = fileURL
        descriptor = openedDescriptor
        device = openedMetadata.st_dev
        inode = openedMetadata.st_ino
        owner = openedMetadata.st_uid
        byteCount = openedMetadata.st_size
    }

    deinit {
        Darwin.close(descriptor)
    }

    func withRevalidatedFileURL<T>(_ operation: (URL) throws -> T) throws -> T {
        var leasedMetadata = stat()
        guard fstat(descriptor, &leasedMetadata) == 0,
              matchesLease(leasedMetadata)
        else { throw WatchPlaybackFileLeaseError.identityDrift }

        var pathMetadata = stat()
        guard lstat(fileURL.path, &pathMetadata) == 0,
              matchesLease(pathMetadata)
        else { throw WatchPlaybackFileLeaseError.identityDrift }

        let verificationDescriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard verificationDescriptor >= 0 else {
            throw WatchPlaybackFileLeaseError.identityDrift
        }
        defer { Darwin.close(verificationDescriptor) }
        var verificationMetadata = stat()
        guard fstat(verificationDescriptor, &verificationMetadata) == 0,
              matchesLease(verificationMetadata)
        else { throw WatchPlaybackFileLeaseError.identityDrift }

        // The store owns cooperative namespace mutation. The retained descriptor
        // pins the validated inode while AVAudioPlayer owns playback, and the path
        // is revalidated immediately around synchronous player construction.
        return try operation(fileURL)
    }

    private func matchesLease(_ metadata: stat) -> Bool {
        Self.isPrivateRegularFile(metadata)
            && metadata.st_dev == device
            && metadata.st_ino == inode
            && metadata.st_uid == owner
            && metadata.st_size == byteCount
    }

    private static func isPrivateRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == geteuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o777 == 0o600
            && metadata.st_size > 0
            && metadata.st_size <= VoiceMemoMetadata.maximumAudioByteCount
    }
}

@MainActor
final class WatchAudioPlayer: NSObject, WatchAudioPlaying, @preconcurrency AVAudioPlayerDelegate {
    private(set) var state: WatchPlaybackState = .stopped
    var onStateChange: ((WatchPlaybackState) -> Void)?
    var hasActivePlaybackLease: Bool { playbackLease != nil }

    private let playerFactory: (URL) throws -> AVAudioPlayer
    private let beforePlayerCreation: (() throws -> Void)?
    private var audioPlayer: AVAudioPlayer?
    private var playbackLease: WatchPlaybackFileLease?

    init(
        playerFactory: @escaping (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) },
        beforePlayerCreation: (() throws -> Void)? = nil
    ) {
        self.playerFactory = playerFactory
        self.beforePlayerCreation = beforePlayerCreation
        super.init()
    }

    func play(memoID: MemoID, url: URL) throws {
        stop()
        do {
            let lease = try WatchPlaybackFileLease(fileURL: url)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            try beforePlayerCreation?()
            let player = try lease.withRevalidatedFileURL(playerFactory)
            player.delegate = self
            guard player.prepareToPlay() else {
                throw WatchAudioPlayerError.couldNotPrepare
            }
            audioPlayer = player
            playbackLease = lease
            guard player.play() else {
                audioPlayer = nil
                playbackLease = nil
                throw WatchAudioPlayerError.couldNotStart
            }
            setState(.playing(memoID))
        } catch {
            audioPlayer?.delegate = nil
            audioPlayer = nil
            playbackLease = nil
            deactivateAudioSession()
            setState(.failed(memoID))
            throw error
        }
    }

    func stop() {
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playbackLease = nil
        deactivateAudioSession()
        setState(.stopped)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        guard player === audioPlayer else { return }
        let finishedMemoID: MemoID?
        if case let .playing(memoID) = state {
            finishedMemoID = memoID
        } else {
            finishedMemoID = nil
        }
        player.delegate = nil
        audioPlayer = nil
        playbackLease = nil
        deactivateAudioSession()
        if successfully || finishedMemoID == nil {
            setState(.stopped)
        } else if let finishedMemoID {
            setState(.failed(finishedMemoID))
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: (any Error)?) {
        guard player === audioPlayer else { return }
        let failedMemoID: MemoID?
        if case let .playing(memoID) = state {
            failedMemoID = memoID
        } else {
            failedMemoID = nil
        }
        player.delegate = nil
        audioPlayer = nil
        playbackLease = nil
        deactivateAudioSession()
        if let failedMemoID {
            setState(.failed(failedMemoID))
        } else {
            setState(.stopped)
        }
    }

    private func setState(_ state: WatchPlaybackState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
