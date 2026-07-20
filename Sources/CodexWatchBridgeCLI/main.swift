import Foundation

Task {
    do {
        try await BridgeCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Foundation.exit(0)
    } catch {
        let detail = String(describing: error)
        FileHandle.standardError.write(Data("codex-watch-bridge: operation failed: \(detail)\n".utf8))
        Foundation.exit(1)
    }
}
dispatchMain()
