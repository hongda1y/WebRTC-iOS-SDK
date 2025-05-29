//
//  PreviewCameraViewController.swift
//  WebRTCiOSSDK
//
//  Created by Socheat on 29/5/25.
//

import Foundation
import AVFoundation
import UIKit
import WebRTCiOSSDK

class PreviewCameraViewController: UIViewController {
    let cameraView = UIView()
    
    let noneButton = UIButton()
    let blurButton = UIButton()
    let imageButton = UIButton()
    
    var cameraManager: PreviewedCameraManager?
    var previewLayer: AVSampleBufferDisplayLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupCameraView()
        setupButton()
    }
    
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        
        setupCameraManager()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        cameraManager?.stopCapture()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = cameraView.bounds
    }
    
    private func setupCameraManager() {
        cameraManager = PreviewedCameraManager()
    
        previewLayer = cameraManager!.getPreviewLayer()
        previewLayer?.bounds = view.bounds
        cameraView.layer.addSublayer(previewLayer!)
        
        cameraManager?.startCapture()
    }
    
    private func setupCameraView() {
        cameraView.layer.cornerRadius = 10
        cameraView.clipsToBounds = true
        view.addSubview(cameraView)
        
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        cameraView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        cameraView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        cameraView.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
    }
    
    private func setupButton() {
        let stack = UIStackView(arrangedSubviews: [noneButton, imageButton, blurButton])
        stack.axis = .horizontal
        
        imageButton.setTitle("Image", for: .normal)
        blurButton.setTitle("Blur", for: .normal)
        noneButton.setTitle("None", for: .normal)
        
        imageButton.setTitleColor(.systemBlue, for: .normal)
        blurButton.setTitleColor(.systemBlue, for: .normal)
        noneButton.setTitleColor(.systemBlue, for: .normal)
        
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor).isActive = true
        stack.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        stack.heightAnchor.constraint(equalToConstant: 40).isActive = true
        
        [noneButton, imageButton, blurButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 80).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 80).isActive = true
        }
        
        blurButton.addTarget(self, action: #selector(onBlurTap), for: .touchUpInside)
        imageButton.addTarget(self, action: #selector(onImageTap), for: .touchUpInside)
        noneButton.addTarget(self, action: #selector(onNoneTap), for: .touchUpInside)
    }
    
    deinit {
        cameraManager?.stopCapture()
        cameraManager = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }
    
    @objc func onBlurTap() {
        cameraManager?.setBackgroundEffect(.blur)
    }

    @objc func onNoneTap() {
        cameraManager?.setBackgroundEffect(nil)
    }
    
    @objc func onImageTap()  {
        if let image = UIImage(named: "conferenceBackground") {
            cameraManager?.setBackgroundEffect(.image(image: image))
        }
    }
    
}

class PreviewedCameraManager: NSObject {
    
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
    private let processingQueue = DispatchQueue(label: "com.camera.processing", qos: .userInitiated)
    private var frameDropCount = 0
    private let maxConsecutiveDrops = 5
    
    // Frame rate limiting
    private var lastFrameTime: CFTimeInterval = 0
    private let targetFrameInterval: CFTimeInterval = 1.0 / 24.0 // 24 FPS
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupCaptureSession()
        setupMemoryWarningObserver()
    }
    
    deinit {
        stopCapture()
        cleanupResources()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Methods
    func startCapture() {
        guard !captureSession.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }
    
    func stopCapture() {
        guard captureSession.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }
    
    func setBackgroundEffect(_ videoEffect: VideoEffect?) {
        self.backgroundEffect = videoEffect
    }
    
    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = currentCameraPosition == .front ? .back : .front
        configureCameraInput(position: newPosition)
    }
    
    func getPreviewLayer() -> AVSampleBufferDisplayLayer {
        if previewLayer == nil {
            setupPreviewLayer()
        }
        return previewLayer!
    }
    
    // MARK: - Memory Management
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        print("Memory warning received - performing cleanup")
        flushPreviewLayer()
        // Optionally reduce quality temporarily
        reduceQualityTemporarily()
    }
    
    private func flushPreviewLayer() {
        previewLayer?.flushAndRemoveImage()
    }
    
    private func reduceQualityTemporarily() {
        // Temporarily reduce session preset if possible
        captureSession.beginConfiguration()
        if captureSession.sessionPreset == .hd1280x720 {
            if captureSession.canSetSessionPreset(.vga640x480) {
                captureSession.sessionPreset = .vga640x480
            }
        }
        captureSession.commitConfiguration()
        
        // Reset to higher quality after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.restoreOriginalQuality()
        }
    }
    
    private func restoreOriginalQuality() {
        captureSession.beginConfiguration()
        if captureSession.canSetSessionPreset(.hd1280x720) {
            captureSession.sessionPreset = .hd1280x720
        }
        captureSession.commitConfiguration()
    }
    
    private func cleanupResources() {
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
    
    private func optimizeImageForBackground(_ image: UIImage) -> UIImage? {
        // Resize background image to reasonable dimensions to save memory
        let maxDimension: CGFloat = 1920 // Max dimension for background
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
        
        if scale < 1.0 {
            let newSize = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            return resizedImage
        }
        
        return image
    }
    
    // MARK: - Private Setup Methods
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        
        // Configure session preset - start with lower quality to save memory
        
        if captureSession.canSetSessionPreset(.vga640x480) {
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
            print("Failed to find camera for position: \(position)")
            return
        }
        
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
                
                // Set frame rate if supported
                if camera.isSmoothAutoFocusSupported {
                    camera.isSmoothAutoFocusEnabled = true
                }
                
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
        
//        // Enable more aggressive sample buffer management
//        previewLayer?.sampleBufferRenderer.requiresFlushToResumeDecoding = false
    }
    
    private func findCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // iOS 10+ discovery session
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera
            ],
            mediaType: .video,
            position: position
        )
        
        return discoverySession.devices.first
    }
    
    private func configureFrameRate(for device: AVCaptureDevice) {
        // Use more conservative frame rate to reduce memory pressure
        let targetFPS: Double = 24 // Reduced from 30 to save memory
        
        for format in device.formats {
            let ranges = format.videoSupportedFrameRateRanges
            
            for range in ranges {
                if range.minFrameRate <= targetFPS && range.maxFrameRate >= targetFPS {
                    device.activeFormat = format
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                    return
                }
            }
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
    
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
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
        processingQueue.async { [weak self] in
            self?.processFrameWithVirtualBackground(sampleBuffer: sampleBuffer, orientation: currentOrientation)
        }
    }
    
    private func processFrameWithVirtualBackground(
        sampleBuffer: CMSampleBuffer,
        orientation: AVCaptureVideoOrientation
    ) {
        isProcessingFrame = true
        
        guard let backgroundEffect else {
            isProcessingFrame = false
            
            if #available(iOS 17.0, *) {
                previewLayer?.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                previewLayer?.enqueue(sampleBuffer)
            }
            
            return
        }
        
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
            
            guard let self else { return }
            
            if let error {
                print("Virtual background processing error: \(error)")
                return
            }
            
            if let maskedSampleBuffer {
                DispatchQueue.main.async { [weak self] in
                    // Check if preview layer is still valid before enqueueing
                    guard let previewLayer = self?.previewLayer else { return }
                    
                    // Flush old samples if queue is getting too full
                    if previewLayer.isReadyForMoreMediaData {
                        previewLayer.enqueue(maskedSampleBuffer)
                    } else {
                        // If not ready, flush and try again
                        previewLayer.flushAndRemoveImage()
                        if previewLayer.isReadyForMoreMediaData {
                            previewLayer.enqueue(maskedSampleBuffer)
                        }
                    }
                }
            }
        }
    }
}
