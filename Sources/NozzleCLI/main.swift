import Foundation
import NozzleCLIKit

let output = CLIRunner.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(output.stdout)
FileHandle.standardError.write(output.stderr)
exit(output.exitCode)
