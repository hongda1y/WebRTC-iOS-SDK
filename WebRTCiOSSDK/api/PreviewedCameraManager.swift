//
//  PreviewedCameraManager.swift
//  WebRTCiOSSDK
//
//  Created by Socheat on 29/5/25.
//

import Foundation
import AVFoundation
import UIKit

public class PreviewedCameraManager: NSObject {
    
    // MARK: - Properties
    private let captureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.camera.capture", qos: .userInitiated)
    
    private var videoInput: AVCaptureDeviceInput?
    private var previewLayer: AVSampleBufferDisplayLayer?
    
    // Virtual background processor
    private let virtualBackground = RTCVirtualBackground()
    private var backgroundEffect: VideoEffect?
    
    // Configuration
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    private var videoOrientation: AVCaptureVideoOrientation = .portrait
    
    // Memory management
    private var isProcessingFrame = false
    //    private let processingQueue = DispatchQueue(label: "com.camera.processing", qos: .userInitiated)
    private var frameDropCount = 0
    private let maxConsecutiveDrops = 5
    
    private var isCameraAvailable: Bool = true
    
    // Frame rate limiting
    private var lastFrameTime: CFTimeInterval = 0
    
    private var targetFrameInterval: CFTimeInterval
    private var targetFrame: CGFloat
    private var preset: AVCaptureSession.Preset
    
    // FIX: Add proper cleanup tracking
    private var isCleanedUp = false
    
    // MARK: - Initialization
    public init(preset: AVCaptureSession.Preset = .vga640x480, frame: CGFloat = 24) {
        self.preset = preset
        self.targetFrameInterval = 1.0 / frame
        self.targetFrame = frame
        
        super.init()
        setupCaptureSession()
    }
    
    deinit {
        stopCapture()
        cleanupResources()
    }
    
    // MARK: - Public Methods
    public func startCapture() {
        guard !captureSession.isRunning, isCameraAvailable else { return }
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }
    
    public func stopCapture() {
        guard captureSession.isRunning, isCameraAvailable else { return }
        
        // FIX: Stop synchronously to ensure proper cleanup
        if Thread.isMainThread {
            DispatchQueue.global(qos: .background).sync { [weak self] in
                self?.captureSession.stopRunning()
            }
        } else {
            captureSession.stopRunning()
        }
    }
    
    //    public func stopCapture() {
    //        guard captureSession.isRunning, isCameraAvailable else { return }
    //
    //        captureSession.stopRunning()
    //
    ////        DispatchQueue.global(qos: .background).async { [weak self] in
    ////            self?.captureSession.stopRunning()
    ////        }
    //    }
    
    public func setBackgroundEffect(_ videoEffect: VideoEffect?) {
        virtualBackground.clearBackgroundImage()
        self.backgroundEffect = videoEffect
    }
    
    public func switchCamera() {
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .front ? .back : .front
        configureCameraInput(position: newPosition)
    }
    
    public func getPreviewLayer() -> AVSampleBufferDisplayLayer {
        if previewLayer == nil {
            setupPreviewLayer()
        }
        return previewLayer!
    }
    
    
    private func flushPreviewLayer() {
        previewLayer?.flushAndRemoveImage()
    }
    
    private func restoreOriginalQuality() {
        captureSession.beginConfiguration()
        if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        }
        captureSession.commitConfiguration()
    }
    
    public func cleanupResources() {
        backgroundEffect = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        
        // Clean up capture session
        captureSession.beginConfiguration()
        if let input = videoInput {
            captureSession.removeInput(input)
        }
        captureSession.removeOutput(videoDataOutput)
        captureSession.commitConfiguration()
    }
    
    //    // ENHANCED RESOURCE CLEANUP - Fixed version
    //    private func cleanupResources() {
    //        guard !isCleanedUp else { return }
    //
    //        print("Starting resource cleanup...")
    //        isCleanedUp = true
    //
    //        // Stop capture session first
    //        if captureSession.isRunning {
    //            captureSession.stopRunning()
    //        }
    //
    //        // Clear background effect first
    //        backgroundEffect = nil
    //        virtualBackground.clearBackgroundImage()
    //
    ////        processingQueue.suspend()
    ////        captureQueue.suspend()
    //
    ////        // Clean up preview layer on main thread
    ////        DispatchQueue.main.sync {
    ////            if let layer = self.previewLayer {
    ////                layer.flushAndRemoveImage()
    ////                layer.removeFromSuperlayer()
    ////
    ////                // Clear the sample buffer renderer
    ////                if #available(iOS 17.0, *) {
    ////                    layer.sampleBufferRenderer.flush()
    ////                }
    ////            }
    ////            self.previewLayer = nil
    ////        }
    ////
    ////        // Clean up capture session
    ////        captureSession.beginConfiguration()
    ////
    ////        // Remove all inputs
    ////        for input in captureSession.inputs {
    ////            captureSession.removeInput(input)
    ////        }
    ////
    ////        // Remove all outputs
    ////        for output in captureSession.outputs {
    ////            captureSession.removeOutput(output)
    ////        }
    ////
    ////        captureSession.commitConfiguration()
    ////
    ////        // Clear references
    ////        videoInput = nil
    //
    //        print("Resources cleaned up successfully")
    //    }
    
    // MARK: - Private Setup Methods
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        
        // Configure session preset - start with lower quality to save memory
        
        if captureSession.canSetSessionPreset(preset) {
            captureSession.sessionPreset = preset
        } else if captureSession.canSetSessionPreset(.vga640x480) {
            captureSession.sessionPreset = .vga640x480
        } else if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        }
        
        // Setup camera input
        configureCameraInput(position: currentCameraPosition)
        
        // Setup video output
        configureVideoOutput()
        
        // Setup preview layer
        setupPreviewLayer()
        
        captureSession.commitConfiguration()
    }
    
    private func configureCameraInput(position: AVCaptureDevice.Position) {
        // Remove existing input
        if let currentInput = videoInput {
            captureSession.removeInput(currentInput)
        }
        
        // Find camera device
        guard let camera = findCamera(position: position) else {
            isCameraAvailable = false
            print("Failed to find camera for position: \(position)")
            return
        }
        
        isCameraAvailable = true
        
        do {
            // Create input
            let newInput = try AVCaptureDeviceInput(device: camera)
            
            // Add input to session
            if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
                videoInput = newInput
                currentCameraPosition = position
                
                // Configure camera settings
                try camera.lockForConfiguration()
                
//                // Set frame rate if supported
//                if camera.isSmoothAutoFocusSupported {
//                    camera.isSmoothAutoFocusEnabled = true
//                }
                
                // Configure frame rate to be more conservative
                configureFrameRate(for: camera)
                
                camera.unlockForConfiguration()
                
            } else {
                print("Cannot add camera input to session")
            }
            
        } catch {
            print("Failed to create camera input: \(error)")
        }
    }
    
    private func configureVideoOutput() {
        // Configure video data output
        videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        
        // Set video settings for memory efficiency
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        
        // Configure output properties for better memory management
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        
        // Add output to session
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
            
            // Configure video orientation
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = videoOrientation
                }
                
                // Mirror front camera
                if currentCameraPosition == .front && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
        } else {
            print("Cannot add video output to session")
        }
    }
    
    private func setupPreviewLayer() {
        previewLayer = AVSampleBufferDisplayLayer()
        previewLayer?.videoGravity = .resizeAspectFill
    }
    
    private func findCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // iOS 10+ discovery session
        var deviceType: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTelephotoCamera
        ]
        
        if #available(iOS 13.0, *) {
            deviceType.append(.builtInUltraWideCamera)
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceType,
            mediaType: .video,
            position: position
        )
        
        return discoverySession.devices.first
    }
    
    //    private func configureFrameRate(for device: AVCaptureDevice) {
    //        // Use more conservative frame rate to reduce memory pressure
    //
    //        for format in device.formats {
    //            let ranges = format.videoSupportedFrameRateRanges
    //
    //            for range in ranges {
    //                if range.minFrameRate <= targetFrame && range.maxFrameRate >= targetFrame {
    //                    device.activeFormat = format
    //                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrame))
    //                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrame))
    //                    return
    //                }
    //            }
    //        }
    //    }
    
    private func configureFrameRate(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // Since you're using AVCaptureSession preset, we only need to configure frame rate
            // The preset already determines the resolution and format
            
            // Find a frame rate range that supports our target
            for range in device.activeFormat.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFrame && range.maxFrameRate >= targetFrame {
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrame))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrame))
                    
                    device.unlockForConfiguration()
                    
                    // Log current format for verification
                    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    print("Frame rate configured: \(dimensions.width)x\(dimensions.height) at \(targetFrame)fps")
                    return
                }
            }
            
            // If target frame rate not supported, find closest supported rate
            var closestRange: AVFrameRateRange?
            var smallestDifference = Double.infinity
            
            for range in device.activeFormat.videoSupportedFrameRateRanges {
                let difference = min(abs(range.minFrameRate - targetFrame), abs(range.maxFrameRate - targetFrame))
                if difference < smallestDifference {
                    smallestDifference = difference
                    closestRange = range
                }
            }
            
            if let range = closestRange {
                // Use the closest supported frame rate
                let actualFrameRate = (targetFrame < range.minFrameRate) ? range.minFrameRate :
                (targetFrame > range.maxFrameRate) ? range.maxFrameRate : targetFrame
                
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFrameRate))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFrameRate))
                
                print("Using closest supported frame rate: \(actualFrameRate)fps (target was \(targetFrame)fps)")
            } else {
                print("Warning: No supported frame rate ranges found")
            }
            
            device.unlockForConfiguration()
            
        } catch {
            print("Error configuring frame rate: \(error)")
        }
    }
    
    // MARK: - Permission Handling
    static func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension PreviewedCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // FIX: Early exit if cleaned up
        guard !isCleanedUp else { return }
        
        // Frame rate limiting to prevent overwhelming the processor
        let currentTime = CACurrentMediaTime()
        if currentTime - lastFrameTime < targetFrameInterval {
            return
        }
        lastFrameTime = currentTime
        
        // Drop frames if we're already processing to prevent memory buildup
        guard !isProcessingFrame else {
            frameDropCount += 1
            if frameDropCount % 10 == 0 {
                print("Dropped \(frameDropCount) frames to manage memory")
            }
            return
        }
        
        // Reset drop count on successful processing
        frameDropCount = 0
        
        // Get current video orientation from connection
        let currentOrientation = connection.videoOrientation
        
        // Process on separate queue to avoid blocking
        processFrameWithVirtualBackground(sampleBuffer: sampleBuffer, orientation: currentOrientation)
    }
    
    private func processFrameWithVirtualBackground(
        sampleBuffer: CMSampleBuffer,
        orientation: AVCaptureVideoOrientation
    ) {
        guard !isCleanedUp, let backgroundEffect else {
            enqueue(sampleBuffer)
            return
        }
        
        isProcessingFrame = true
        
        var backgroundImage: UIImage?
        switch backgroundEffect {
        case .image(let image):
            backgroundImage = image
        default:
            backgroundImage = nil
        }
        
        virtualBackground.processAVCaptrueForegroundMask(
            from: sampleBuffer,
            backgroundImage: backgroundImage
        ) { [weak self] maskedSampleBuffer, error in
            
            defer {
                self?.isProcessingFrame = false
            }
            
            guard let self, !isCleanedUp else { return }
            
            if let error {
                print("Virtual background processing error: \(error)")
                return
            }
            
            if let maskedSampleBuffer {
                DispatchQueue.main.async { [weak self] in
                    // Check if preview layer is still valid before enqueueing
                    guard let self, let previewLayer = self.previewLayer else { return }
                    
                    // Flush old samples if queue is getting too full
                    if previewLayer.isReadyForMoreMediaData {
                        self.enqueue(maskedSampleBuffer)
                    } else {
                        // If not ready, flush and try again
                        previewLayer.flushAndRemoveImage()
                        if previewLayer.isReadyForMoreMediaData {
                            self.enqueue(maskedSampleBuffer)
                        }
                    }
                }
            }
        }
        //        }
    }
    
    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard !isCleanedUp, let previewLayer else { return }
        
        if #available(iOS 17.0, *) {
            previewLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            previewLayer.enqueue(sampleBuffer)
        }
    }
}
