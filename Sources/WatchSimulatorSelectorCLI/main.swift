import Foundation

Task {
    let result = await WatchSimulatorSelectorCommand.run(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
    FileHandle.standardError.write(Data(result.stderr.utf8))
    Foundation.exit(result.exitCode.rawValue)
}
dispatchMain()
