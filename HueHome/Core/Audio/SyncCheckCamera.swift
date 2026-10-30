// SyncCheckCamera.swift
// ChromaGlow — Core/Audio (chunk 2, item 3: Sync Check)
//
// The back camera at its fastest frame rate (240 fps where the phone has
// it), each frame reduced to a grid of brightness cells and stamped on the
// host clock CACurrentMediaTime reads — the clock the stream loop stamps
// blink sends with. Nothing is recorded or kept: a frame becomes 144
// numbers and is released.
//
// The stamp is the frame's capture time (its presentation timestamp,
// converted from the session's clock) plus half the exposure, so a sample
// stands for the middle of the light it integrated. Exposure and white
// balance are locked before the blinks start, with the exposure biased
// down so a bulb in view is not clipped.
//
// Device only: the simulator has no camera (`start` throws `.noCamera`).

import AVFoundation
import CoreMedia
import Foundation

final class SyncCheckCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum SetupError: Error, Equatable {
        case noCamera
        case cannotConfigure
    }

    let session = AVCaptureSession()

    /// Session configuration, start and stop: never on the main thread
    /// (iOS reports a blocking camera start there as a hang).
    private let sessionQueue = DispatchQueue(label: "ChromaGlow.SyncCheck.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "ChromaGlow.SyncCheck.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()

    private let lock = NSLock()
    private var device: AVCaptureDevice?
    private var syncClock: CMClock?
    private var recording = false
    private var samples: [SyncCheckSample] = []
    private var halfExposure: Double = 0
    private var _frameRate: Double = 0
    private var _framesSeen = 0

    /// Frames per second the camera was set to.
    var frameRate: Double {
        lock.lock(); defer { lock.unlock() }
        return _frameRate
    }

    /// Frames delivered since start (the preview is live once this moves).
    var framesSeen: Int {
        lock.lock(); defer { lock.unlock() }
        return _framesSeen
    }

    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    // MARK: Lifecycle

    /// Configures the back camera at its fastest frame rate and starts it.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureAndStart()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        recording = false
        samples = []
        lock.unlock()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndStart() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw SetupError.noCamera
        }
        let rate = try configure(camera)
        lock.lock()
        device = camera
        syncClock = session.synchronizationClock
        _frameRate = rate
        _framesSeen = 0
        lock.unlock()
        session.startRunning()
    }

    /// Returns the frame rate set.
    private func configure(_ camera: AVCaptureDevice) throws -> Double {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            throw SetupError.cannotConfigure
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { throw SetupError.cannotConfigure }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        // The format goes on AFTER the input joins the session, or the
        // session's preset overrides it.
        let rate: Double
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if let (format, fastest) = Self.fastestFormat(of: camera) {
                camera.activeFormat = format
                let frame = CMTime(value: 1, timescale: CMTimeScale(fastest))
                camera.activeVideoMinFrameDuration = frame
                camera.activeVideoMaxFrameDuration = frame
                rate = fastest
            } else {
                rate = 30
            }
            if camera.activeFormat.isVideoHDRSupported {
                camera.automaticallyAdjustsVideoHDREnabled = false
                camera.isVideoHDREnabled = false
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            // About a stop and a half under the auto exposure: the lit room
            // reads mid-grey and a bulb in view stays below white.
            camera.setExposureTargetBias(max(camera.minExposureTargetBias, -1.5), completionHandler: nil)
        } catch {
            throw SetupError.cannotConfigure
        }
        return rate
    }

    /// The highest-rate 4:2:0 format, capped at 240 fps, at the smallest
    /// size that rate offers (fewer pixels to reduce).
    static func fastestFormat(of camera: AVCaptureDevice) -> (AVCaptureDevice.Format, Double)? {
        var best: (format: AVCaptureDevice.Format, rate: Double, width: Int32)?
        for format in camera.formats {
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 640 else { continue }
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rate = min(240, maxRate.rounded(.down))
            guard rate >= 30 else { continue }
            if let current = best {
                if rate > current.rate || (rate == current.rate && dims.width < current.width) {
                    best = (format, rate, dims.width)
                }
            } else {
                best = (format, rate, dims.width)
            }
        }
        return best.map { ($0.format, $0.rate) }
    }

    // MARK: Exposure

    /// Freeze exposure and white balance where they settled, so a blink
    /// changes the picture and the camera does not chase it.
    func lockExposure() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.lock.lock()
                let camera = self.device
                self.lock.unlock()
                if let camera, (try? camera.lockForConfiguration()) != nil {
                    if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
                    if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
                    let exposure = CMTimeGetSeconds(camera.exposureDuration)
                    camera.unlockForConfiguration()
                    self.lock.lock()
                    self.halfExposure = exposure.isFinite && exposure > 0 ? exposure / 2 : 0
                    self.lock.unlock()
                }
                continuation.resume()
            }
        }
    }

    /// Back to automatic exposure and white balance (biased down as at
    /// start), so the next check settles on the room afresh.
    func resumeAutoExposure() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.lock.lock()
                let camera = self.device
                self.halfExposure = 0
                self.lock.unlock()
                if let camera, (try? camera.lockForConfiguration()) != nil {
                    if camera.isExposureModeSupported(.continuousAutoExposure) {
                        camera.exposureMode = .continuousAutoExposure
                        camera.setExposureTargetBias(max(camera.minExposureTargetBias, -1.5), completionHandler: nil)
                    }
                    if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        camera.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    camera.unlockForConfiguration()
                }
                continuation.resume()
            }
        }
    }

    // MARK: Recording

    func beginRecording() {
        lock.lock()
        samples = []
        samples.reserveCapacity(5_000)
        recording = true
        lock.unlock()
    }

    func endRecording() -> [SyncCheckSample] {
        lock.lock(); defer { lock.unlock() }
        recording = false
        let taken = samples
        samples = []
        return taken
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        _framesSeen += 1
        let wanted = recording
        let clock = syncClock
        let offset = halfExposure
        lock.unlock()
        guard wanted, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        let time = CMTimeGetSeconds(host) + offset
        guard time.isFinite else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let cells = SyncCheckLuma.grid(base.assumingMemoryBound(to: UInt8.self),
                                       width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                                       height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                                       bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        lock.lock()
        if recording { samples.append(SyncCheckSample(time: time, cells: cells)) }
        lock.unlock()
    }
}
