import Foundation
import DirectRTC

// Usage: swift run PacketReplay /path/capture.dotcall /path/new-output-folder
// Writes files only. It never plays audio or connects to a server.
do {
    guard CommandLine.arguments.count >= 3 else { throw DirectRTCError("Usage: PacketReplay CAPTURE.dotcall NEW_OUTPUT_DIRECTORY [--compression] [--backlog-ms=1000] [--max-speed=1.10]") }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard !FileManager.default.fileExists(atPath: output.path) else { throw DirectRTCError("Output directory already exists.") }
    let options = Array(CommandLine.arguments.dropFirst(3))
    var backlog = 500, speed = 1.10, compression = false
    for option in options {
        if option == "--compression" { compression = true }
        else if option == "--no-compression" { compression = false }
        else if option.hasPrefix("--backlog-ms="), let value = Int(option.dropFirst(13)) { backlog = value }
        else if option.hasPrefix("--max-speed="), let value = Double(option.dropFirst(12)), value.isFinite { speed = value }
        else { throw DirectRTCError("Invalid replay option: \(option)") }
    }
    let result = try PacketReplay.replay(url: input, compressionEnabled: compression, backlogMilliseconds: backlog, maximumSpeed: speed)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try PacketReplay.wav(result.arrivalPCM, sampleRate: result.sampleRate).write(to: output.appendingPathComponent("arrival-playout.wav"), options: .withoutOverwriting)
    try PacketReplay.wav(result.referencePCM, sampleRate: result.sampleRate).write(to: output.appendingPathComponent("timestamp-reference.wav"), options: .withoutOverwriting)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result.metrics).write(to: output.appendingPathComponent("metrics.json"), options: .withoutOverwriting)
    try encoder.encode(result.diagnostics).write(to: output.appendingPathComponent("diagnostics.json"), options: .withoutOverwriting)
    let timing = result.sampleRate == 48000
        ? "Native NetEq follows captured 10 ms pulls; the timestamp-order reference starts at first packet availability. Their output offsets are not matched speech boundaries."
        : "Both legacy outputs share the first decoded media anchor."
    print("Wrote renderer reconstruction, timestamp-order reference, and metrics at \(result.sampleRate) Hz. \(timing) Render-gap silence models scheduling; it does not record the speaker. The reference preserves missing-packet gaps and cannot recover missing audio or reproduce browser ChatGPT playback.")
} catch {
    FileHandle.standardError.write(Data("Replay failed: \(error.localizedDescription)\n".utf8)); exit(1)
}
