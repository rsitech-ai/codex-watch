import Foundation

let options: CodexCompatibilitySmokeOptions
do {
    options = try CodexCompatibilitySmokeCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data((CodexCompatibilitySmokeCommand.usage + "\n").utf8))
    exit(64)
}

let semaphore = DispatchSemaphore(value: 0)
var commandExit: Int32 = 3
Task {
    commandExit = await CodexCompatibilitySmokeCommand.run(options)
    semaphore.signal()
}
semaphore.wait()
exit(commandExit)
