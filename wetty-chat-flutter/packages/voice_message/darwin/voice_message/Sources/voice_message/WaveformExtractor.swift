import AVFoundation

/// Extracts normalized waveform peak samples from audio files.
///
/// Uses `AVAssetReader` for Apple-native formats (M4A, AAC, MP3, WAV, MP4)
/// and `OGGDecoder` for OGG/Opus files.
enum WaveformExtractor {

    enum WaveformError: Error {
        case noAudioTrack
        case failedToCreateReader(Error)
        case failedToCreateReaderOutput
        case failedToStartReader(Error?)
        case failedToReadAsset(Error?)
        case failedToAccessSampleData
        case unsupportedSampleFormat
    }

    /// Extract waveform peaks from an audio file.
    ///
    /// Returns an array of `samplesCount` values, each normalized to 0–255.
    static func extract(path: String, samplesCount: Int) throws -> [Int] {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        let rawSamples: [Float]
        if ext == "ogg" || ext == "opus" {
            rawSamples = try extractFromOgg(url: url)
        } else {
            rawSamples = try extractFromAssetReader(url: url)
        }

        return downsampleAndNormalize(rawSamples, to: samplesCount)
    }

    // MARK: - AVAssetReader (M4A, AAC, MP3, WAV, MP4, etc.)

    private static func extractFromAssetReader(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw WaveformError.noAudioTrack
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WaveformError.failedToCreateReader(error)
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WaveformError.failedToCreateReaderOutput
        }
        reader.add(output)

        guard reader.startReading() else {
            throw WaveformError.failedToStartReader(reader.error)
        }

        var samples = [Float]()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            samples.append(contentsOf: try floatSamples(from: sampleBuffer))
            CMSampleBufferInvalidate(sampleBuffer)
        }

        switch reader.status {
        case .completed:
            return samples
        case .failed, .cancelled:
            throw WaveformError.failedToReadAsset(reader.error)
        case .unknown, .reading:
            if !samples.isEmpty {
                return samples
            }
            throw WaveformError.failedToReadAsset(reader.error)
        @unknown default:
            throw WaveformError.failedToReadAsset(reader.error)
        }
    }

    // MARK: - OGG/Opus via OGGDecoder

    private static func extractFromOgg(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let decoder = try OGGDecoder(audioData: data)
        let pcmData = decoder.pcmData

        // OGGDecoder produces interleaved Float32 PCM
        let floatCount = pcmData.count / MemoryLayout<Float>.stride
        return pcmData.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer.prefix(floatCount))
        }
    }

    // MARK: - Downsample + Normalize

    /// Compresses raw PCM samples into `targetCount` peak bars, normalized to 0–255.
    ///
    /// Mirrors the algorithm from `audio_waveform_cache_service.dart`:
    /// divide samples into equal chunks, find the absolute peak in each chunk,
    /// then scale the global maximum to 255.
    private static func downsampleAndNormalize(_ samples: [Float], to targetCount: Int) -> [Int] {
        guard !samples.isEmpty, targetCount > 0 else {
            return Array(repeating: 0, count: targetCount)
        }

        let chunkSize = Double(samples.count) / Double(targetCount)
        var peaks = [Float]()
        peaks.reserveCapacity(targetCount)

        for i in 0..<targetCount {
            let start = Int(Double(i) * chunkSize)
            let end = min(Int(Double(i + 1) * chunkSize), samples.count)
            var peak: Float = 0
            for j in start..<max(start + 1, end) {
                let absVal = Swift.abs(samples[j])
                if absVal > peak { peak = absVal }
            }
            peaks.append(peak)
        }

        // Find global peak for normalization
        let globalPeak = peaks.max() ?? 0
        guard globalPeak > 0 else {
            return Array(repeating: 0, count: targetCount)
        }

        return peaks.map { peak in
            Int((peak / globalPeak * 255).rounded()).clamped(to: 0...255)
        }
    }

    private static func floatSamples(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw WaveformError.unsupportedSampleFormat
        }
        let streamDescription = streamDescriptionPointer.pointee
        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
        let bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        let floatSize = MemoryLayout<Float>.stride
        guard bytesPerFrame >= channelCount * floatSize else {
            throw WaveformError.unsupportedSampleFormat
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw WaveformError.failedToAccessSampleData
        }
        let dataLength = CMBlockBufferGetDataLength(blockBuffer)
        if dataLength == 0 {
            return []
        }

        var rawBytes = [UInt8](repeating: 0, count: dataLength)
        let status = CMBlockBufferCopyDataBytes(
            blockBuffer,
            atOffset: 0,
            dataLength: dataLength,
            destination: &rawBytes
        )
        guard status == kCMBlockBufferNoErr else {
            throw WaveformError.failedToAccessSampleData
        }

        let totalFloats = dataLength / floatSize
        let totalFrames = totalFloats / channelCount
        if totalFrames == 0 {
            return []
        }

        return rawBytes.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            if channelCount == 1 {
                return Array(floatBuffer.prefix(totalFrames))
            }

            var samples = [Float]()
            samples.reserveCapacity(totalFrames)
            for frame in 0..<totalFrames {
                var peak: Float = 0
                let baseIndex = frame * channelCount
                for channel in 0..<channelCount {
                    peak = max(peak, Swift.abs(floatBuffer[baseIndex + channel]))
                }
                samples.append(peak)
            }
            return samples
        }
    }

}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
