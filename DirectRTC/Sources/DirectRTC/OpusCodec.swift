import AVFAudio
import Foundation

// One channel, 24 kHz PCM16; Opus always uses a 48 kHz RTP timestamp clock.
// AVAudioConverter is a codec only. It never opens an audio device.
public final class OpusCodec {
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter
    private let encodeFrames: Int
    public init(frameSize: Int = 480) throws {
        guard [60, 120, 240, 480, 960, 1440].contains(frameSize) else { throw DirectRTCError("Unsupported Opus frame duration.") }
        encodeFrames = frameSize
        pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
        var format = AudioStreamBasicDescription(mSampleRate: 24000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let encoderOpus = AVAudioFormat(streamDescription: &format)
        format.mFramesPerPacket = 0
        guard let opus = AVAudioFormat(streamDescription: &format), let encoderOpus, let encoder = AVAudioConverter(from: pcm, to: encoderOpus), let decoder = AVAudioConverter(from: opus, to: pcm) else { throw DirectRTCError("Opus audio codec is unavailable on this device.") }
        self.opus = opus; self.encoder = encoder; self.decoder = decoder
        encoder.bitRate = 32000; encoder.primeMethod = .none; decoder.primeMethod = .none
    }
    public func encode(_ input: Data) throws -> Data {
        guard input.count == encodeFrames * 2 else { throw DirectRTCError("Opus PCM input does not match the configured frame duration.") }
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(encodeFrames))!
        buffer.frameLength = AVAudioFrameCount(encodeFrames)
        _ = input.withUnsafeBytes { raw in memcpy(buffer.int16ChannelData![0], raw.baseAddress!, input.count) }
        let output = AVAudioCompressedBuffer(format: encoder.outputFormat, packetCapacity: 1, maximumPacketSize: max(1275, encoder.maximumOutputPacketSize))
        var supplied = false, error: NSError?
        let status = encoder.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard status != .error, output.packetCount == 1 else { throw DirectRTCError("Opus encoder did not produce an audio packet.") }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
    public func decode(_ packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= 61440, let duration = ReceiveJitterBuffer.opusDuration(packet) else { throw DirectRTCError("Invalid Opus packet size.") }
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        input.packetCount = 1; input.byteLength = UInt32(packet.count)
        _ = packet.withUnsafeBytes { raw in memcpy(input.data, raw.baseAddress!, packet.count) }
        input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(duration / 2), mDataByteSize: UInt32(packet.count))
        let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 5760)!
        var supplied = false, error: NSError?
        let status = decoder.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw DirectRTCError("Could not decode call audio.") }
        return Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2)
    }
}
