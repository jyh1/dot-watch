import AVFAudio

// A converter belongs to one input format and is replaced after a hardware route change.
final class MicrophonePCM {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    init(source: AVAudioFormat) throws {
        guard source.sampleRate > 0, source.channelCount > 0,
              let converter = AVAudioConverter(from: source, to: format) else {
            throw RelayFailure(message: "The Watch microphone format is unavailable.")
        }
        self.converter = converter
    }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / buffer.format.sampleRate) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RelayFailure(message: "Cannot allocate Watch microphone audio.")
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard let floats = output.floatChannelData?[0] else { return Data() }
        var samples = [Int16](repeating: 0, count: Int(output.frameLength))
        for i in samples.indices {
            let value = floats[i].isFinite ? floats[i] : 0
            samples[i] = Int16(max(-32768, min(32767, Int(max(-1, min(1, value)) * 32767)))).littleEndian
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
