import Foundation

Task {
    let result = await WatchDevicePreflightCommand.run(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    FileHandle.standardOutput.write(Data(result.output.utf8))
    Foundation.exit(result.exitCode.rawValue)
}
dispatchMain()
