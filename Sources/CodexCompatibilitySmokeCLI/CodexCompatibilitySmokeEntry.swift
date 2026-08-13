import Foundation

@main
enum CodexCompatibilitySmokeEntry {
    static func main() async {
        let options: CodexCompatibilitySmokeOptions
        do {
            options = try CodexCompatibilitySmokeCommand.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data((CodexCompatibilitySmokeCommand.usage + "\n").utf8))
            exit(64)
        }

        exit(await CodexCompatibilitySmokeCommand.run(options))
    }
}
