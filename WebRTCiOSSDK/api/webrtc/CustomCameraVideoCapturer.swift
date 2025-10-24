/*
 * Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS.  All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

import AVFoundation
import CoreMedia
import UIKit
import WebRTC

// MARK: - Constants

private enum Constants {
    static let nanosecondsPerSecond: Int64 = 1_000_000_000
    static let supportedPixelFormats: Set<FourCharCode> = [
        kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
}

// MARK: - Helper Extensions

private extension AVCaptureSession.InterruptionReason {
    var description: String {
        switch self {
        case .videoDeviceNotAvailableInBackground:
            return "Video device is not available in the background."
        case .audioDeviceInUseByAnotherClient:
            return "Audio device is in use by another client."
        case .videoDeviceInUseByAnotherClient:
            return "Video device is in use by another client."
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "Video device is not available with multiple foreground apps."
        default:
            return "Unknown interruption reason."
        }
    }
}

private extension AVCaptureDevice {
    /// Device types available for video capture, organized by iOS version
    static var availableDeviceTypes: [AVCaptureDevice.DeviceType] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTelephotoCamera
        ]
        
        if #available(iOS 11.1, *) {
            deviceTypes.append(.builtInTrueDepthCamera)
        }
        
        if #available(iOS 13.0, *) {
            deviceTypes.append(contentsOf: [
                .builtInUltraWideCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ])
        }
        
        if #available(iOS 10.2, *) {
            deviceTypes.append(.builtInDualCamera)
        }
        
        return deviceTypes
    }
}

// MARK: - Main Class

final class CustomCameraVideoCapturer: RTCVideoCapturer {
    
    // MARK: - State Management
    
    private enum CaptureState {
        case idle
        case starting
        case running
        case stopping
        case error(Error)
    }
    
    // MARK: - Properties
    
    private let captureSession: AVCaptureSession
    private let videoDataOutput: AVCaptureVideoDataOutput
    private let captureSessionQueue: DispatchQueue
    private let frameProcessingQueue: DispatchQueue
    
    private var currentDevice: AVCaptureDevice?
    private var currentDeviceInput: AVCaptureDeviceInput?
    private var captureState: CaptureState = .idle
    private var hasRetriedOnFatalError = false
    
    // Thread-safe orientation tracking
    private let orientationQueue = DispatchQueue(label: "orientation.queue", qos: .utility)
    private var _currentInterfaceOrientation: UIInterfaceOrientation = .unknown
    private var currentInterfaceOrientation: UIInterfaceOrientation {
        get {
            return orientationQueue.sync { _currentInterfaceOrientation }
        }
        set {
            orientationQueue.async { [weak self] in
                guard let self = self else { return }
                self._currentInterfaceOrientation = newValue
            }
        }
    }
    
    // MARK: - Initialization
    
    override init(delegate: RTCVideoCapturerDelegate) {
        self.captureSession = AVCaptureSession()
        self.videoDataOutput = AVCaptureVideoDataOutput()
        self.captureSessionQueue = DispatchQueue(
            label: "org.webrtc.cameravideocapturer.capturesession",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        self.frameProcessingQueue = DispatchQueue(
            label: "org.webrtc.cameravideocapturer.frameprocessing",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        
        super.init(delegate: delegate)
        
        // Initialize orientation safely
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentInterfaceOrientation = self.interfaceOrientation
        }
        
        setupCaptureSession()
        addNotificationObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        // Ensure cleanup happens synchronously without weak reference
//        captureSessionQueue.sync {
            cleanupCaptureSession()
//        }
    }
    
    // MARK: - Public API
    
    func startCapture(
        with device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        fps: Int
    ) {
        captureSessionQueue.async { [weak self] in
            self?.performStartCapture(device: device, format: format, fps: fps)
        }
    }
    
    func stopCapture() {
        captureSessionQueue.async { [weak self] in
            self?.performStopCapture()
        }
    }
    
    // MARK: - Class Methods
    
    static func captureDevices() -> [AVCaptureDevice] {
        if #available(iOS 10.0, *) {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: AVCaptureDevice.availableDeviceTypes,
                mediaType: .video,
                position: .unspecified
            )
            return discoverySession.devices
        } else {
            // Fallback for iOS 9 and earlier
            return AVCaptureDevice.devices(for: .video)
        }
    }
    
    static func supportedFormats(for device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        return device.formats.filter { format in
            let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return Constants.supportedPixelFormats.contains(mediaSubType)
        }
    }
    
    // MARK: - Private Implementation
    
    private func setupCaptureSession() {
        captureSession.sessionPreset = .inputPriority
        captureSession.usesApplicationAudioSession = false
        
        configureVideoDataOutput()
        
        guard captureSession.canAddOutput(videoDataOutput) else {
            assertionFailure("Cannot add video data output to capture session")
            return
        }
        
        captureSession.addOutput(videoDataOutput)
    }
    
    private func configureVideoDataOutput() {
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true // Optimize for real-time performance
        videoDataOutput.setSampleBufferDelegate(self, queue: frameProcessingQueue)
    }
    
    private func performStartCapture(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        guard case .idle = captureState else {
            print("Cannot start capture: current state is \(captureState)")
            return
        }
        
        captureState = .starting
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            try configureDevice(device, format: format, fps: fps)
            try configureCaptureSessionInput(for: device)
            
            captureSession.startRunning()
            captureState = .running
            currentDevice = device
            
        } catch {
            captureState = .error(error)
            print("Failed to start capture: \(error.localizedDescription)")
        }
    }
    
    private func performStopCapture() {
        guard case .running = captureState else {
            print("Cannot stop capture: current state is \(captureState)")
            return
        }
        
        captureState = .stopping
        
        // Stop the session
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        
        captureSession.beginConfiguration()
        
        // Clear delegate to prevent callbacks
        videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
        
        // Remove inputs only (keep output for potential restart)
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        
        captureSession.commitConfiguration()
        
        // Reset state
        currentDevice = nil
        currentDeviceInput = nil
        
        // Re-configure video output for future use
        configureVideoDataOutput()
        
        captureState = .idle
    }
    
    private func configureDevice(_ device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) throws {
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        
        // Optimize for low-light performance if available
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        
        // Configure focus and exposure for better video quality
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }
    
    private func configureCaptureSessionInput(for device: AVCaptureDevice) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Remove existing input
        if let currentInput = currentDeviceInput {
            captureSession.removeInput(currentInput)
        }
        
        // Add new input
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(deviceInput) else {
            throw CaptureError.cannotAddInput
        }
        
        captureSession.addInput(deviceInput)
        currentDeviceInput = deviceInput
    }
    
    private func cleanupCaptureSession() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        
        captureSession.beginConfiguration()
        
        // Clear delegate to prevent callbacks during cleanup
        videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
        
        // Remove inputs and outputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        
        captureSession.commitConfiguration()
        
        // Reset state
        currentDevice = nil
        currentDeviceInput = nil
    }
    
    private var interfaceOrientation: UIInterfaceOrientation {
        if #available(iOS 13.0, *),
           let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            return windowScene.interfaceOrientation
        } else {
            return UIApplication.shared.statusBarOrientation
        }
    }
    
    private func videoRotation(for orientation: UIInterfaceOrientation, isUsingFrontCamera: Bool) -> RTCVideoRotation {
        switch orientation {
        case .portrait:
            return ._90
        case .portraitUpsideDown:
            return ._270
        case .landscapeLeft:
            return isUsingFrontCamera ? ._0 : ._180
        case .landscapeRight:
            return isUsingFrontCamera ? ._180 : ._0
        case .unknown:
            return ._90
        @unknown default:
            return ._90
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CustomCameraVideoCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if #available(iOS 17.0, *) {
            print(#function, connection.videoRotationAngle)
        } else {
            print(#function, connection.videoOrientation)
        }
        
        // Early validation for performance
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        // Determine camera position efficiently
        let isUsingFrontCamera = connection.inputPorts
            .compactMap { $0.input as? AVCaptureDeviceInput }
            .first?.device.position == .front
        
        let rotation = videoRotation(
            for: currentInterfaceOrientation,
            isUsingFrontCamera: isUsingFrontCamera
        )
        
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs = Int64(
            CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) *
            Double(Constants.nanosecondsPerSecond)
        )
        
        let videoFrame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: rotation,
            timeStampNs: timeStampNs
        )
        
        delegate?.capturer(self, didCapture: videoFrame)
    }
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Only log in debug builds to avoid performance impact
        #if DEBUG
        print("Video frame dropped")
        #endif
    }
}

// MARK: - Notification Handling

private extension CustomCameraVideoCapturer {
    
    func addNotificationObservers() {
        let center = NotificationCenter.default
        
        // Orientation changes
        center.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIApplication.didChangeStatusBarOrientationNotification,
            object: nil
        )
        
        // Session notifications
        let sessionNotifications: [(Notification.Name, Selector)] = [
            (.AVCaptureSessionWasInterrupted, #selector(sessionWasInterrupted)),
            (.AVCaptureSessionInterruptionEnded, #selector(sessionInterruptionEnded)),
            (.AVCaptureSessionRuntimeError, #selector(sessionRuntimeError)),
            (.AVCaptureSessionDidStartRunning, #selector(sessionDidStartRunning)),
            (.AVCaptureSessionDidStopRunning, #selector(sessionDidStopRunning))
        ]
        
        sessionNotifications.forEach { notification, selector in
            center.addObserver(
                self,
                selector: selector,
                name: notification,
                object: captureSession
            )
        }
        
        // Application lifecycle
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc func orientationDidChange() {
        currentInterfaceOrientation = interfaceOrientation
    }
    
    @objc func sessionWasInterrupted(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            return
        }
        print("Capture session interrupted: \(reason.description)")
    }
    
    @objc func sessionInterruptionEnded() {
        print("Capture session interruption ended")
    }
    
    @objc func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            return
        }
        
        print("Capture session runtime error: \(error.localizedDescription)")
        
        captureSessionQueue.async { [weak self] in
            if error.code == .mediaServicesWereReset {
                self?.handleRecoverableError()
            } else {
                self?.handleFatalError()
            }
        }
    }
    
    @objc func sessionDidStartRunning() {
        captureSessionQueue.async { [weak self] in
            self?.hasRetriedOnFatalError = false
        }
    }
    
    @objc func sessionDidStopRunning() {
        print("Capture session stopped")
    }
    
    @objc func applicationDidBecomeActive() {
        captureSessionQueue.async { [weak self] in
            guard let self = self,
                  case .running = self.captureState,
                  !self.captureSession.isRunning else {
                return
            }
            
            print("Restarting capture session after app became active")
            self.captureSession.startRunning()
        }
    }
    
    func handleFatalError() {
        guard !hasRetriedOnFatalError else {
            print("Previous fatal error recovery failed, not retrying")
            return
        }
        
        print("Attempting to recover from fatal error")
        handleRecoverableError()
        hasRetriedOnFatalError = true
    }
    
    func handleRecoverableError() {
        guard case .running = captureState else { return }
        
        print("Restarting capture session after recoverable error")
        captureSession.startRunning()
    }
}

// MARK: - Error Types

private enum CaptureError: Error, LocalizedError {
    case cannotAddInput
    case deviceConfigurationFailed
    case sessionSetupFailed
    
    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add camera input to capture session"
        case .deviceConfigurationFailed:
            return "Failed to configure camera device"
        case .sessionSetupFailed:
            return "Failed to setup capture session"
        }
    }
}
