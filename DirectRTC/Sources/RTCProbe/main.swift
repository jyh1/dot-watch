import Foundation
import DirectRTC
import Synchronization

@main struct Probe {
 static func main() async throws {
  let dir = URL(fileURLWithPath: CommandLine.arguments[1])
  let peer = try DirectPeer()
  let count = Mutex(0)
  peer.onOpus = { _,_,_ in count.withLock { $0 += 1 } }
  defer { peer.close() }
  try peer.offer.write(to:dir.appendingPathComponent("offer.sdp"),atomically:true,encoding:.utf8)
  for _ in 0..<300 { if FileManager.default.fileExists(atPath:dir.appendingPathComponent("answer.sdp").path) { break }; try await Task.sleep(for:.milliseconds(100)) }
  var answer = try String(contentsOf:dir.appendingPathComponent("answer.sdp"),encoding:.utf8)
  if CommandLine.arguments.contains("--wrong-fingerprint") {
   answer = answer.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }).map { String(decoding:$0,as:UTF8.self) }.map { line in
    line.hasPrefix("a=fingerprint:sha-256 ") ? "a=fingerprint:sha-256 " + Array(repeating:"00",count:32).joined(separator:":") : line
   }.joined(separator:"\r\n") + "\r\n"
   do { try await peer.connect(answer:answer) }
   catch {
    guard !peer.mediaReady, String(describing:error).lowercased().contains("fingerprint") else { throw error }
    print("PASS: wrong server fingerprint rejected before media")
    try Data().write(to:dir.appendingPathComponent("done")); return
   }
   throw DirectRTCError("Accepted wrong server fingerprint")
  }
  try await peer.connect(answer:answer)
  let pipeline = try DirectAudioPipeline(peer: peer)
  pipeline.start()
  defer { pipeline.stop() }
  for n in 0..<500 {
   let samples = (0..<480).map { Int16(sin(Double(n*480+$0)*2*Double.pi*660/24000)*5000).littleEndian }
   pipeline.push(samples.withUnsafeBytes { Data($0) })
   _ = pipeline.takeOutput()
   if let error = pipeline.failure { throw DirectRTCError(error) }
   try await Task.sleep(for:.milliseconds(20))
  }
  let stats = pipeline.statistics
  print("Direct transport state=\(peer.state) audio=\(stats)")
  try JSONSerialization.data(withJSONObject: stats).write(to:dir.appendingPathComponent("watch-result.json"))
  try Data().write(to:dir.appendingPathComponent("done"))
  guard stats["receivedPackets", default:0] > 10, stats["decodedPeak", default:0] > 1000 else { throw DirectRTCError("No remote audio decoded") }
 }
}
