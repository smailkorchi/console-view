import AVFoundation

// This path is used only after the device identity and native 96 kHz mono
// descriptor have been checked. Each adjacent pair is really 48 kHz L/R.
final class MS2109Audio: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let capacity = 48_000 * 2 * 120 / 1000
    private let cushion = 48_000 * 2 * 30 / 1000
    private var ring = [Float](repeating: 0, count: 48_000 * 2 * 120 / 1000)
    private var head = 0
    private var count = 0
    private var pendingSample: Float?
    private var primed = false
    private var reportedInvalidFormat = false
    private var setupError: Error?
    var onFailure: ((String) -> Void)?

    override init() {
        super.init()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frames, buffers in
            self?.render(Int(frames), buffers)
            return noErr
        }
        engine.attach(source)
        if #available(macOS 27, *) {
            do { try engine.connectNode(source, to: engine.mainMixerNode, format: format) }
            catch { setupError = error }
        } else {
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
    }

    func start(volume: Float) throws {
        if let setupError { throw setupError }
        setVolume(volume)
        try engine.start()
    }

    func setVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(volume, 1))
    }

    func stop() {
        engine.stop()
        lock.lock()
        head = 0
        count = 0
        pendingSample = nil
        primed = false
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mFormatID == kAudioFormatLinearPCM,
              format.pointee.mSampleRate == 96_000,
              format.pointee.mChannelsPerFrame == 1,
              format.pointee.mBitsPerChannel == 32,
              format.pointee.mBytesPerFrame == MemoryLayout<Float>.size,
              format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            reportInvalidFormat()
            return
        }

        var buffers = AudioBufferList()
        var retainedBlock: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &buffers,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock)
        let samples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard result == noErr, samples > 0, buffers.mNumberBuffers == 1,
              buffers.mBuffers.mNumberChannels == 1,
              let data = buffers.mBuffers.mData,
              buffers.mBuffers.mDataByteSize % UInt32(MemoryLayout<Float>.size) == 0,
              samples <= Int(buffers.mBuffers.mDataByteSize) / MemoryLayout<Float>.size,
              let retainedBlock,
              CMBlockBufferGetDataLength(retainedBlock) >= Int(buffers.mBuffers.mDataByteSize) else {
            reportInvalidFormat()
            return
        }
        withExtendedLifetime(retainedBlock) {
            push(data.assumingMemoryBound(to: Float.self), samples: samples)
        }
    }

    private func reportInvalidFormat() {
        guard !reportedInvalidFormat else { return }
        reportedInvalidFormat = true
        onFailure?("Capture audio changed format. Video is still available.")
    }

    private func push(_ samples: UnsafePointer<Float>, samples length: Int) {
        lock.lock()
        var index = 0
        if let pendingSample {
            appendPair(pendingSample, samples[0])
            self.pendingSample = nil
            index = 1
        }
        while index + 1 < length {
            appendPair(samples[index], samples[index + 1])
            index += 2
        }
        if index < length { pendingSample = samples[index] }
        lock.unlock()
    }

    // Called with the lock held; trimming always preserves left/right parity.
    private func appendPair(_ left: Float, _ right: Float) {
        if count + 2 > capacity {
            let drop = count - cushion
            head = (head + drop) % capacity
            count -= drop
        }
        let write = (head + count) % capacity
        ring[write] = left
        ring[(write + 1) % capacity] = right
        count += 2
    }

    private func render(_ frames: Int, _ buffers: UnsafeMutablePointer<AudioBufferList>) {
        let output = UnsafeMutableAudioBufferListPointer(buffers)
        guard output.count == 2,
              output[0].mDataByteSize >= frames * MemoryLayout<Float>.size,
              output[1].mDataByteSize >= frames * MemoryLayout<Float>.size,
              let leftData = output[0].mData, let rightData = output[1].mData else { return }
        let left = leftData.assumingMemoryBound(to: Float.self)
        let right = rightData.assumingMemoryBound(to: Float.self)
        let needed = frames * 2
        lock.lock()
        if !primed { primed = count >= cushion + needed }
        guard primed, count >= needed else {
            primed = false
            lock.unlock()
            left.initialize(repeating: 0, count: frames)
            right.initialize(repeating: 0, count: frames)
            return
        }
        for frame in 0..<frames {
            left[frame] = ring[head]
            right[frame] = ring[(head + 1) % capacity]
            head = (head + 2) % capacity
        }
        count -= needed
        lock.unlock()
    }
}
