import Foundation
import AVFAudio

// PCM state and graph operations use separate locks. Lifecycle and UI callbacks
// stay on main; the media pump may schedule playback on its serial queue.
final class CallAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private let graphLock = NSRecursiveLock()
    private var input = Data()
    private var muted = false
    private var playbackQueue = PlaybackQueue(sampleRate: 48000)
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var started = false
    private var captureRequired = false
    private var rebuilding = false
    private var recoveryAttempts = 0
    private var bytesAtRecovery = 0
    private var lastPCM = Date()
    private var lastReport = Date.distantPast
    private var tapCount = 0, convertedBytes = 0, receivedBytes = 0, outputPeak = 0, playedBuffers = 0
    private var conversionError: String?
    var onFailure: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onProgress: ((String) -> Void)?
    #if targetEnvironment(simulator)
    private var simulated: Bool { ProcessInfo.processInfo.arguments.contains("--simulated-audio") }
    private var simulatedSample = 0, simulatedReceived = 0, simulatedPeak = 0
    private var renderTapInstalled = false
    private var renderedFrames = 0, renderedPeak: Float = 0
    private var faultTimer: Timer?
    #endif

    func requestPermission() async throws {
        #if targetEnvironment(simulator)
        if simulated { return }
        #endif
        onProgress?("Requesting microphone permission")
        let permission = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard permission else { throw RelayFailure(message: "Allow microphone access in Settings to talk to Dot.") }
    }
    func start() throws {
        graphLock.lock(); defer { graphLock.unlock() }
        #if targetEnvironment(simulator)
        if simulated { started = true; print("SIMULATOR: using generated microphone tone, no audio hardware"); return }
        #endif
        // CallKit configured and activated the session before the engine starts.
        let session = AVAudioSession.sharedInstance()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.onInterrupted?()
        })
        engine.attach(player)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        onProgress?("Call voice processing enabled")
        try configureGraph()
        started = true
        #if targetEnvironment(simulator)
        // Exercise recovery using an actual stopped AVAudioEngine, not fake state.
        if ProcessInfo.processInfo.arguments.contains("--stop-audio-engine-once") {
            faultTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.onProgress?("SIMULATOR TEST: stopping the real audio engine once")
                self?.graphLock.lock()
                self?.engine.stop()
                self?.graphLock.unlock()
            }
        }
        #endif
        // Configuration notifications originate on an internal audio queue. Rebuild
        // asynchronously on main, never inside that notification's delivery stack.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.checkHealth(configurationChanged: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            self?.reportRoute()
        })
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        reportRoute()
    }
    private func configureGraph() throws {
        graphLock.lock(); defer { graphLock.unlock() }
        rebuilding = true
        defer { rebuilding = false }
        player.stop(); engine.stop()
        #if targetEnvironment(simulator)
        if renderTapInstalled { engine.mainMixerNode.removeTap(onBus: 0); renderTapInstalled = false }
        #endif
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        // VoiceProcessingIO requires equal input and output hardware formats.
        // Keep the mixer output at the microphone rate; it converts the 48 kHz
        // Dot stream instead of allowing that stream to select the I/O rate.
        let hardware = engine.inputNode.outputFormat(forBus: 0)
        let converter = try MicrophonePCM(source: hardware)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        #if targetEnvironment(simulator)
        // Simulator QA must not play through the user's Mac speakers. Physical
        // builds never compile this setting. Mixer frame counts still validate
        // rendering, but a muted mixer peak is not evidence of audible output.
        engine.mainMixerNode.outputVolume = 0
        // Measure actual mixer output, not bytes merely queued to AVAudioPlayerNode.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            guard let self, let floats = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(floats[i])) }
            self.lock.lock()
            self.renderedFrames += Int(buffer.frameLength); self.renderedPeak = max(self.renderedPeak, peak)
            self.lock.unlock()
        }
        renderTapInstalled = true
        #endif
        lock.lock()
        input.removeAll(); playbackQueue.clear(); lastPCM = Date(); conversionError = nil; bytesAtRecovery = convertedBytes
        lock.unlock()
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); self.tapCount += 1; self.lock.unlock()
            do {
                let data = try converter.convert(buffer)
                self.lock.lock()
                if !data.isEmpty { self.lastPCM = Date(); self.convertedBytes += data.count }
                if !self.muted {
                    self.input.append(data)
                    if self.input.count > 9600 { self.input.removeFirst(self.input.count - 9600) }
                }
                self.lock.unlock()
            } catch {
                self.lock.lock(); self.conversionError = error.localizedDescription; self.lock.unlock()
            }
        }
        tapInstalled = true
        engine.prepare(); try engine.start(); player.play()
        onProgress?("Call audio engine started: input \(hardware.sampleRate) Hz/\(hardware.channelCount) ch, output \(engine.outputNode.inputFormat(forBus: 0).sampleRate) Hz")
    }
    private func reportRoute() {
        let session = AVAudioSession.sharedInstance()
        // Port types only: Bluetooth accessory names can contain personal details.
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        lock.lock(); playbackQueue.updateRoute(outputLatency: session.outputLatency, ioBufferDuration: session.ioBufferDuration); lock.unlock()
        onProgress?("Call audio route: in [\(inputs)], out [\(outputs)], volume \(String(format: "%.2f", session.outputVolume))")
    }
    func connected() {
        // Do not time out microphone delivery while the system is still presenting
        // an outgoing connection. Require actual capture once Dot is connected.
        captureRequired = true
        lock.lock(); lastPCM = Date(); lock.unlock()
    }
    private func checkHealth(configurationChanged: Bool = false) {
        graphLock.lock()
        let shouldCheck = started && !rebuilding
        let running = engine.isRunning, playing = player.isPlaying
        graphLock.unlock()
        guard shouldCheck else { return }
        let now = Date()
        lock.lock()
        let age = now.timeIntervalSince(lastPCM)
        let details = "taps \(tapCount), converted \(convertedBytes) bytes, received \(receivedBytes) bytes, output peak \(outputPeak), played \(playedBuffers), queued \(playbackQueue.buffers), queued ms \(Int(playbackQueue.seconds * 1000)), max queued ms \(Int(playbackQueue.maximumSeconds * 1000)), queue resets \(playbackQueue.resets), output latency ms \(Int(playbackQueue.outputLatency * 1000))"
        let error = conversionError
        let hasRecovered = convertedBytes > bytesAtRecovery
        lock.unlock()
        if configurationChanged || now.timeIntervalSince(lastReport) >= 5 {
            onProgress?("Call audio health: running \(running), playing \(playing), \(details)")
            if let error { onProgress?("Call audio conversion: \(error)") }
            #if targetEnvironment(simulator)
            lock.lock(); let frames = renderedFrames, peak = renderedPeak; renderedPeak = 0; lock.unlock()
            onProgress?("SIMULATOR real mixer: rendered \(frames) frames, peak \(peak)")
            #endif
            lastReport = now
        }
        guard !running || (captureRequired && age > 3) else {
            if hasRecovered { recoveryAttempts = 0 }
            return
        }
        guard recoveryAttempts < 2 else {
            onFailure?("The Microphone is not delivering audio. End the call and reopen Dot Watch.")
            return
        }
        recoveryAttempts += 1
        onProgress?("Recovering Call audio: engine running \(running), microphone stalled \(String(format: "%.1f", age))s")
        do { try configureGraph(); reportRoute() }
        catch { onFailure?("Call audio restart failed: \(error.localizedDescription)") }
    }
    func takeInput() -> Data {
        #if targetEnvironment(simulator)
        if simulated {
            lock.lock(); defer { lock.unlock() }
            let samples = (0..<240).map { i in Int16(sin(Double(simulatedSample+i) * 2 * .pi * 660 / 24000) * 5000).littleEndian }
            simulatedSample += samples.count
            return muted ? Data(count:480) : samples.withUnsafeBytes { Data($0) }
        }
        #endif
        lock.lock(); defer { lock.unlock() }
        let data = input; input.removeAll(keepingCapacity: true); return data
    }
    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; input.removeAll(keepingCapacity: true); lock.unlock()
    }
    func play(_ data: Data) {
        graphLock.lock(); defer { graphLock.unlock() }
        guard started, !rebuilding else { return }
        #if targetEnvironment(simulator)
        if simulated {
            lock.lock(); defer { lock.unlock() }
            simulatedReceived += data.count
            data.withUnsafeBytes { bytes in
                for i in stride(from:0,to:data.count,by:2) { simulatedPeak = max(simulatedPeak,abs(Int(bytes.loadUnaligned(fromByteOffset:i,as:Int16.self)))) }
            }
            if simulatedSample % 24000 < 240 { print("SIMULATOR: Watch received \(simulatedReceived) PCM bytes, peak \(simulatedPeak), muted \(muted)") }
            return
        }
        #endif
        guard !data.isEmpty, data.count % 2 == 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let floats = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        var peak = 0
        data.withUnsafeBytes { bytes in
            for i in 0..<data.count / 2 {
                let value = bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                peak = max(peak, abs(Int(Int16(littleEndian: value))))
                floats[i] = Float(Int16(littleEndian: value)) / 32768
            }
        }
        lock.lock()
        receivedBytes += data.count; outputPeak = max(outputPeak, peak)
        let frameCount = Int(buffer.frameLength)
        let admission = playbackQueue.admit(frames: frameCount)
        lock.unlock()
        // stop() can invoke completion callbacks that acquire lock.
        if admission.reset { player.stop(); player.play() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.playbackQueue.complete(frames: frameCount, generation: admission.generation) { self.playedBuffers += 1 }
            self.lock.unlock()
        }
    }
    func stop() {
        graphLock.lock(); defer { graphLock.unlock() }
        #if targetEnvironment(simulator)
        if simulated { started = false; print("SIMULATOR: Call audio ended"); return }
        #endif
        started = false
        #if targetEnvironment(simulator)
        faultTimer?.invalidate(); faultTimer = nil
        if renderTapInstalled { engine.mainMixerNode.removeTap(onBus: 0); renderTapInstalled = false }
        #endif
        healthTimer?.invalidate(); healthTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop(); engine.stop()
        lock.lock(); input.removeAll(); playbackQueue.clear(); lock.unlock()
        // CallKit owns deactivation after the call is reported ended.
    }
}
