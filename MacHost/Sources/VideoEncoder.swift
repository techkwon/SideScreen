import Foundation
import VideoToolbox
import CoreMedia
import os

class VideoEncoder {
    /// Scratch bytes reserved at the front of every encoded frame so the wire
    /// header can be written in place. Sized for the largest header format
    /// (`[type 1][size 4][keyframe 1][capture timestamp 8]`); the shorter legacy
    /// header is written at the tail of the same region. Without this the whole
    /// frame had to be copied into a fresh buffer just to prepend a few bytes.
    static let headerRoom = 14

    private struct EncoderState {
        var pendingForceKeyframe = false
    }

    private var compressionSession: VTCompressionSession?
    // Passed `inout` so the header can be patched into the reserved room without
    // tripping copy-on-write — the buffer must stay uniquely referenced.
    var onEncodedFrame: ((inout Data, UInt64, Bool) -> Void)?  // data, timestamp, isKeyframe
    private var width: Int
    private var height: Int
    private var bitrateMbps: Int = 20
    private var quality: String = "medium"
    private var gamingBoost: Bool = false
    private var frameRate: Int = 60
    private let stateLock = OSAllocatedUnfairLock(initialState: EncoderState())
    init(width: Int, height: Int, bitrateMbps: Int = 20, quality: String = "ultralow", gamingBoost: Bool = false, frameRate: Int = 60) {
        self.width = width
        self.height = height
        self.bitrateMbps = gamingBoost ? 50 : bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost
        self.frameRate = frameRate
        setupCompressionSession()
    }

    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        self.bitrateMbps = gamingBoost ? 50 : bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost

        // Drain pending frames before invalidation
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        setupCompressionSession()
    }

    private func setupCompressionSession() {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, // H.265
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            debugLog("Failed to create compression session: \(status)")
            return
        }

        compressionSession = session

        // Ultra-low latency config for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)

        // Dynamic bitrate - remove strict rate limiting for smoother streaming
        // All-intra needs higher bitrate for text sharpness
        // USB-C supports 5Gbps, so 80-100Mbps is fine
        let effectiveBitrate = gamingBoost ? bitrateMbps : max(bitrateMbps, 60)
        let bitrateBps = effectiveBitrate * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        // Removed DataRateLimits - was causing bursty traffic and buffer stalls

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        // Short-GOP IPP: 1 keyframe per second, P-frames in between.
        // All-intra (every frame keyframe) was producing 3-5x more data than needed,
        // saturating tablet decode/compose pipeline at high panel resolutions and
        // starving Mac WindowServer with encoder load. Short-GOP IPP gives 99% of
        // the resilience (frame loss recovery within 1 second) at a fraction of
        // the per-frame cost. TCP over USB-C rarely drops, so 1s GOP is safe.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: frameRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)

        // Critical for low latency - NO frame reordering (no B-frames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // ALWAYS zero frame delay for real-time streaming (not just gaming boost)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Quality based on preset
        let qualityValue: Float
        if gamingBoost {
            qualityValue = 0.3  // Ultra low quality for maximum speed
        } else {
            qualityValue = switch quality {
            case "ultralow": 0.5  // Still fast but better text readability
            case "low": 0.65
            case "medium": 0.8   // Sharp text for productivity
            case "high": 0.9     // Very sharp, higher bitrate
            default: 0.5
            }
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: qualityValue as CFNumber)

        // Use VBR (variable bitrate) instead of CBR for burst capacity during fast scene changes
        // CBR causes over-quantization (blocky artifacts) when scene complexity spikes
        // Removed: kVTCompressionPropertyKey_ConstantBitRate

        VTCompressionSessionPrepareToEncodeFrames(session)

        let mode = gamingBoost ? "🎮 GAMING BOOST" : quality.uppercased()
        debugLog("VideoToolbox encoder configured (H.265, \(bitrateMbps)Mbps, \(frameRate)fps, \(mode))")
    }

    /// Force the next encoded frame to be an IDR (sync) frame.
    /// Used when a fresh client connects so its decoder can start immediately
    /// instead of waiting up to one full GOP for the next scheduled keyframe.
    func requestKeyframe() {
        stateLock.withLock { $0.pendingForceKeyframe = true }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = compressionSession else { return }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        // Use system uptime clock — MUST match DispatchTime.now().uptimeNanoseconds.
        // VideoToolbox treats sourceFrameRefcon as an opaque value and hands it back
        // untouched, so the timestamp rides in the pointer's bit pattern rather than
        // in an 8-byte heap block allocated and freed once per frame.
        let captureNanos = DispatchTime.now().uptimeNanoseconds
        let refconValue = UnsafeMutableRawPointer(bitPattern: UInt(captureNanos))

        let shouldForceKeyframe = stateLock.withLock { state -> Bool in
            guard state.pendingForceKeyframe else { return false }
            state.pendingForceKeyframe = false
            return true
        }
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: refconValue,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

// Static start code to avoid repeated allocations
private let nalStartCode: [UInt8] = [0, 0, 0, 1]

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, _, sampleBuffer) in
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          let refcon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()

    // Get timestamp for frame age tracking. The refcon carries the capture time
    // directly in its bit pattern (see encode); nil only when that value was zero,
    // which uptime nanoseconds never realistically is.
    let timestamp: UInt64
    if let refcon = sourceFrameRefCon {
        timestamp = UInt64(UInt(bitPattern: refcon))
    } else {
        timestamp = DispatchTime.now().uptimeNanoseconds
    }

    // Extract encoded data
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let statusCode = CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )

    guard statusCode == kCMBlockBufferNoErr,
          let dataPointer = dataPointer else {
        return
    }

    // Check if this is a keyframe
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let attachmentKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    let nalKeyframe = containsHEVCSyncNALs(dataPointer: dataPointer, totalLength: totalLength)
    let isKeyframe = attachmentKeyframe || nalKeyframe

    // Pre-allocate estimated size to reduce reallocations
    let estimatedSize = VideoEncoder.headerRoom + totalLength + (isKeyframe ? 256 : 0) + 32
    var frameData = Data(capacity: estimatedSize)
    // Reserve (zero-filled) space for the wire header; StreamingServer patches it
    // in place so the frame is never copied a second time on the way out.
    frameData.count = VideoEncoder.headerRoom

    if isKeyframe {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Get parameter sets (SPS, PPS, VPS for H.265)
            var parameterSetCount: Int = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)

            for i in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize: Int = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

                if let pointer = parameterSetPointer {
                    frameData.append(contentsOf: nalStartCode)
                    frameData.append(pointer, count: parameterSetSize)
                }
            }
        }
    }

    // Convert length-prefixed NAL units to Annex-B format (start codes)
    var offset = 0
    while offset < totalLength {
        // Read 4-byte length
        var nalLength: UInt32 = 0
        memcpy(&nalLength, dataPointer.advanced(by: offset), 4)
        nalLength = UInt32(bigEndian: nalLength)
        offset += 4

        // Add start code and NAL unit data
        frameData.append(contentsOf: nalStartCode)
        let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: offset))
        frameData.append(nalPointer.assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
        offset += Int(nalLength)
    }

    encoder.onEncodedFrame?(&frameData, timestamp, isKeyframe)
}

private func containsHEVCSyncNALs(dataPointer: UnsafeMutablePointer<Int8>, totalLength: Int) -> Bool {
    var offset = 0
    while offset + 6 <= totalLength {
        var nalLength: UInt32 = 0
        memcpy(&nalLength, dataPointer.advanced(by: offset), 4)
        nalLength = UInt32(bigEndian: nalLength)
        offset += 4

        let length = Int(nalLength)
        guard length > 1, offset + length <= totalLength else { return false }

        let firstHeaderByte = UInt8(bitPattern: dataPointer.advanced(by: offset).pointee)
        let nalType = (firstHeaderByte >> 1) & 0x3f
        if (16...21).contains(nalType) {
            return true
        }

        offset += length
    }
    return false
}
