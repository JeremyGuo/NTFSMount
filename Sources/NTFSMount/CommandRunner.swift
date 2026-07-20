import Foundation
import NTFSMountShared

struct CommandResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum CommandRunner {
    static func run(executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    static func runAsAdministrator(shellCommand: String) throws -> CommandResult {
        let escaped = ShellUtilities.appleScriptString(shellCommand)
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return try run(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }
}
