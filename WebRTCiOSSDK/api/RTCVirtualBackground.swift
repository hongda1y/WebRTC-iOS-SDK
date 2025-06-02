//
//  RTCVirtualBackground.swift
//  WebRTCiOSSDK
//

import Foundation
import AVFoundation
import Vision
import VisionKit
import OpenGLES
import WebRTC
import CoreImage
import VideoToolbox

@objc public class RTCVirtualBackground: NSObject {
    
    public typealias ForegroundMaskCompletion = (RTCVideoFrame?, Error?) -> Void
    public typealias ForegroundMaskAVCaptureCompletion = (CMSampleBuffer?, Error?) -> Void
    
    // MARK: - Properties
    private let processingQueue = DispatchQueue(label: "com.webrtc.virtualbackground", qos: .userInitiated)
    private let ciContext: CIContext
    private var backgroundCIImage: CIImage?
    private var cachedBlurredBackground: CIImage?
    private var lastFrameSize: CGSize = .zero
    
    private let blurRadius: Float
    
    // Reusable filters for better performance
    private let gaussianBlurFilter: CIFilter?
    
    // MEMORY MANAGEMENT: Add pixel buffer pool for reuse
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolFrameSize: CGSize = .zero
    
    // MEMORY MANAGEMENT: Limit concurrent processing
//    private let processingGroup = DispatchGroup()
    private let maxConcurrentProcessing = 2
    private var currentProcessingCount = 0
    private let countLock = NSLock()
    
    private lazy var personMaskRequest: Any? = {
        if #available(iOS 17.0, *) {
            let request = VNGeneratePersonInstanceMaskRequest()
            request.revision = VNGeneratePersonInstanceMaskRequestRevision1
            return request
        }
        return nil
    }()
    
    // MARK: - Initialization
    public init(blurRadius: Float = 10) {
        self.blurRadius = blurRadius
        
        // Initialize CI context with Metal for better performance
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice, options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
                .cacheIntermediates: false
            ])
        } else {
            self.ciContext = CIContext(options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
                .cacheIntermediates: false
            ])
        }
        
        // Pre-create reusable filter
        self.gaussianBlurFilter = CIFilter(name: "CIGaussianBlur")
        
        super.init()
    }
    
    deinit {
        // MEMORY MANAGEMENT: Clean up resources
        print("Release all resource...")
        
        if let pool = pixelBufferPool {
            CVPixelBufferPoolFlush(pool, [])
        }
        
        backgroundCIImage = nil
        cachedBlurredBackground = nil
        pixelBufferPool = nil
        
//        processingGroup.wait()
    }
    
    // MEMORY MANAGEMENT: Throttle processing
    private func canProcessFrame() -> Bool {
        countLock.lock()
        defer { countLock.unlock() }
        
        if currentProcessingCount >= maxConcurrentProcessing {
            return false
        }
        currentProcessingCount += 1
        return true
    }
    
    private func decrementProcessingCount() {
        countLock.lock()
        defer { countLock.unlock() }
        currentProcessingCount = max(0, currentProcessingCount - 1)
    }
    
    public func processAVCaptrueForegroundMask(
        from sampleBuffer: CMSampleBuffer,
        backgroundImage: UIImage?,
        completion: @escaping ForegroundMaskAVCaptureCompletion
    ) {
        // MEMORY MANAGEMENT: Throttle processing
        guard canProcessFrame() else {
            completion(nil, NSError(domain: "RTCVirtualBackground", code: -4,
                                  userInfo: [NSLocalizedDescriptionKey: "Processing throttled"]))
            return
        }
        
        // Check iOS version availability upfront
        guard #available(iOS 17.0, *) else {
            decrementProcessingCount()
            completion(nil, NSError(domain: "RTCVirtualBackground", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Vision framework not available"]))
            return
        }
        
//        processingGroup.enter()
        
        processingQueue.async { [weak self] in
//        DispatchQueue.global(qos: .background).async { [weak self] in
            defer {
                self?.decrementProcessingCount()
//                self?.processingGroup.leave()
            }
            
            guard let self = self else { return }
            
            
            completion(sampleBuffer, nil)
            return
            
            // Extract pixel buffer from sample buffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                DispatchQueue.main.async {
                    completion(nil, NSError(domain: "RTCVirtualBackground", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to extract CVPixelBuffer from CMSampleBuffer"]))
                }
                return
            }
            
            // Check if we should process this frame (skip if too frequent)
            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                 height: CVPixelBufferGetHeight(pixelBuffer))
            
            // Cache background image if changed
            self.updateBackgroundImageIfNeeded(backgroundImage)
            
            // Get orientation info
            let videoOrientation = AVCaptureVideoOrientation.portrait
            
            let inputFrameImage = CIImage(cvPixelBuffer: pixelBuffer)
            let handler = VNImageRequestHandler(ciImage: inputFrameImage, options: [:])
            
            do {
                guard let personMaskRequest = personMaskRequest as? VNGeneratePersonInstanceMaskRequest else {
                    return
                }
                
                try handler.perform([personMaskRequest])
                
                let observation = personMaskRequest.results?.first
                let allInstances = observation?.allInstances
                
                var maskedImage: CVPixelBuffer?
                if let allInstances {
                    maskedImage = try observation?.generateMaskedImage(
                        ofInstances: allInstances,
                        from: handler,
                        croppedToInstancesExtent: false
                    )
                }
                
                self.applyForegroundMaskForAVCapture(
                    to: maskedImage,
                    fullPixelBuffer: pixelBuffer,
                    originalSampleBuffer: sampleBuffer,
                    videoOrientation: videoOrientation,
                    frameSize: frameSize,
                    completion: { maskedSampleBuffer, error in
                        DispatchQueue.main.async {
                            if let maskedSampleBuffer {
                                completion(maskedSampleBuffer, nil)
                            } else {
                                completion(nil, error)
                            }
                        }
                    }
                )
                
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
    
    private func applyForegroundMaskForAVCapture(
        to maskedPixelBuffer: CVPixelBuffer?,
        fullPixelBuffer: CVPixelBuffer,
        originalSampleBuffer: CMSampleBuffer,
        videoOrientation: AVCaptureVideoOrientation,
        frameSize: CGSize,
        completion: @escaping (CMSampleBuffer?, Error?) -> Void
    ) {
        // Create CIImage from the masked foreground
        var maskedCIImage: CIImage?
        if let maskedPixelBuffer {
            maskedCIImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
        }
        
        let finalCompositeImage: CIImage
        
        if let backgroundCIImage = self.backgroundCIImage {
            // Use custom background
            finalCompositeImage = self.compositeWithBackgroundForAVCapture(
                foreground: maskedCIImage,
                background: backgroundCIImage,
                size: frameSize,
                videoOrientation: videoOrientation
            )
        } else {
            // Use blurred background
            finalCompositeImage = self.compositeWithBlurredBackground(
                foreground: maskedCIImage,
                fullPixelBuffer: fullPixelBuffer,
                frameSize: frameSize
            )
        }
        
        // MEMORY MANAGEMENT: Use pixel buffer pool
        self.convertCIImageToPixelBufferWithPool(finalCompositeImage, size: frameSize) { [weak self] pixelBuffer in
            if let pixelBuffer {
                let sampleBuffer = self?.createSampleBufferFrom(pixelBuffer: pixelBuffer,
                                                                sampleBuffer: originalSampleBuffer)
                completion(sampleBuffer, nil)
            } else {
                completion(nil, NSError(domain: "RTCVirtualBackground", code: -5,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to create output pixel buffer"]))
            }
        }
    }
    
    // MARK: - Public Methods
    public func processForegroundMask(
        from videoFrame: RTCVideoFrame,
        backgroundImage: UIImage?,
        completion: @escaping ForegroundMaskCompletion
    ) {
        // MEMORY MANAGEMENT: Throttle processing
        guard canProcessFrame() else {
            completion(nil, NSError(domain: "RTCVirtualBackground", code: -4,
                                  userInfo: [NSLocalizedDescriptionKey: "Processing throttled"]))
            return
        }
        
        // Check iOS version availability upfront
        guard #available(iOS 17.0, *) else {
            decrementProcessingCount()
            completion(nil, NSError(domain: "RTCVirtualBackground", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Vision framework not available"]))
            return
        }
        
//        DispatchQueue.global(qos: .background).async { [weak self] in
        processingQueue.async { [weak self] in
            defer { self?.decrementProcessingCount() }
            
            guard let self = self else { return }
            
            guard let pixelBuffer = self.convertRTCVideoFrameToPixelBuffer(videoFrame) else {
                DispatchQueue.main.async {
                    completion(nil, NSError(domain: "RTCVirtualBackground", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to convert RTCVideoFrame to CVPixelBuffer"]))
                }
                return
            }
            
            // Cache background image if changed
            self.updateBackgroundImageIfNeeded(backgroundImage)
            
            let inputFrameImage = CIImage(cvPixelBuffer: pixelBuffer)
            let handler = VNImageRequestHandler(ciImage: inputFrameImage, options: [:])
            
            do {
                guard let personMaskRequest = personMaskRequest as? VNGeneratePersonInstanceMaskRequest else {
                    return
                }
                
                try handler.perform([personMaskRequest])
                
                let observation = personMaskRequest.results?.first
                let allInstances = observation?.allInstances
                
                var maskedImage: CVPixelBuffer?
                if let allInstances {
                    maskedImage = try observation?.generateMaskedImage(
                        ofInstances: allInstances,
                        from: handler,
                        croppedToInstancesExtent: false
                    )
                }
                
                self.applyForegroundMask(
                    to: maskedImage,
                    fullPixelBuffer: pixelBuffer,
                    rotation: videoFrame.rotation,
                    completion: { maskedPixelBuffer, error in
                        DispatchQueue.main.async {
                            if let maskedPixelBuffer = maskedPixelBuffer {
                                let frameProcessed = self.convertPixelBufferToRTCVideoFrame(
                                    maskedPixelBuffer,
                                    rotation: videoFrame.rotation,
                                    timeStampNs: videoFrame.timeStampNs
                                )
                                completion(frameProcessed, nil)
                            } else {
                                completion(nil, error)
                            }
                        }
                    }
                )
                
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
    
    func clearBackgroundImage() {
        backgroundCIImage = nil
    }
    
    // MARK: - Private Methods
    private func updateBackgroundImageIfNeeded(_ backgroundImage: UIImage?) {
        guard let backgroundImage = backgroundImage else {
            self.backgroundCIImage = nil
            return
        }
        
        if self.backgroundCIImage == nil {
            // Resize background image to reasonable size to save memory
//            let maxDimension: CGFloat = 1920
            let resizedImage = resizeImageIfNeeded(backgroundImage)
            self.backgroundCIImage = CIImage(image: resizedImage)
        }
    }
    
//    private func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
//        let size = image.size
//        if size.width <= maxDimension && size.height <= maxDimension {
//            return image
//        }
//        
//        let ratio = min(maxDimension / size.width, maxDimension / size.height)
//        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
//        
//        let renderer = UIGraphicsImageRenderer(size: newSize)
//        return renderer.image { _ in
//            image.draw(in: CGRect(origin: .zero, size: newSize))
//        }
//    }
    
    private func resizeImageIfNeeded(_ image: UIImage) -> UIImage {
        let screenSize = UIScreen.main.bounds.size
        
        // Calculate target size based on screen dimensions with scale factor
        let targetSize = CGSize(
            width: screenSize.width,
            height: screenSize.height
        )
        
        let imageSize = image.size
        
        // If image is already smaller than or equal to target size, return original
        if imageSize.width <= targetSize.width && imageSize.height <= targetSize.height {
            return image
        }
        
        // Calculate scaling ratio to fit within screen bounds while maintaining aspect ratio
        let widthRatio = targetSize.width / imageSize.width
        let heightRatio = targetSize.height / imageSize.height
        let scaleFactor = min(widthRatio, heightRatio)
        
        let newSize = CGSize(
            width: imageSize.width * scaleFactor,
            height: imageSize.height * scaleFactor
        )
        
//        let renderer = UIGraphicsImageRenderer(size: newSize)
//        return renderer.image { _ in
//            image.draw(in: CGRect(origin: .zero, size: newSize))
//        }
        
        // Use more memory-efficient image resizing
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // Don't use device scale since we already calculated it
        format.opaque = true // Optimize for opaque images
        
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    private func applyForegroundMask(
        to maskedPixelBuffer: CVPixelBuffer?,
        fullPixelBuffer: CVPixelBuffer,
        rotation: RTCVideoRotation,
        completion: @escaping (CVPixelBuffer?, Error?) -> Void
    ) {
        let frameSize = CGSize(
            width: CVPixelBufferGetWidth(fullPixelBuffer),
            height: CVPixelBufferGetHeight(fullPixelBuffer)
        )
        
        // Create CIImage from the masked foreground
        var maskedCIImage: CIImage?
        if let maskedPixelBuffer {
            maskedCIImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
        }
        
        let finalCompositeImage: CIImage
        
        if let backgroundCIImage = self.backgroundCIImage {
            // Use custom background
            finalCompositeImage = self.compositeWithBackground(
                foreground: maskedCIImage,
                background: backgroundCIImage,
                size: frameSize,
                rotation: rotation
            )
        } else {
            // Use blurred background
            finalCompositeImage = self.compositeWithBlurredBackground(
                foreground: maskedCIImage,
                fullPixelBuffer: fullPixelBuffer,
                frameSize: frameSize
            )
        }
        
        // MEMORY MANAGEMENT: Use pixel buffer pool
        self.convertCIImageToPixelBufferWithPool(finalCompositeImage, size: frameSize) { pixelBuffer in
            completion(pixelBuffer, nil)
        }
    }
    
    // MEMORY MANAGEMENT: Improved pixel buffer creation with pooling
    private func convertCIImageToPixelBufferWithPool(
        _ ciImage: CIImage,
        size: CGSize,
        completion: @escaping (CVPixelBuffer?) -> Void
    ) {
        // Create or reuse pixel buffer pool
        if pixelBufferPool == nil || poolFrameSize != size {
            createPixelBufferPool(size: size)
        }
        
        guard let pool = pixelBufferPool else {
            completion(nil)
            return
        }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            completion(nil)
            return
        }
        
        // Render using CIContext
        ciContext.render(ciImage, to: buffer)
        completion(buffer)
    }
    
    private func createPixelBufferPool(size: CGSize) {
        if let oldPool = pixelBufferPool {
            CVPixelBufferPoolFlush(oldPool, [])
        }
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 10
        ]
        
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &newPool
        )
        
        if status == kCVReturnSuccess {
            pixelBufferPool = newPool
            poolFrameSize = size
        }
    }
    
    // Rest of the methods remain the same but with memory optimizations...
    
    private func compositeWithBackground(
        foreground: CIImage?,
        background: CIImage,
        size: CGSize,
        rotation: RTCVideoRotation
    ) -> CIImage {
        // Apply rotation to background
        let rotatedBackground = self.applyRotationToBackground(background, rotation: rotation)
        
        // Scale background to fill frame (aspect fill)
        let scaleX = size.width / rotatedBackground.extent.width
        let scaleY = size.height / rotatedBackground.extent.height
        let fillScale = max(scaleX, scaleY)
        
        let scaledBackground = rotatedBackground.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        
        // Center and crop background
        let offsetX = (scaledBackground.extent.width - size.width) / 2
        let offsetY = (scaledBackground.extent.height - size.height) / 2
        let cropRect = CGRect(x: offsetX, y: offsetY, width: size.width, height: size.height)
        let croppedBackground = scaledBackground.cropped(to: cropRect)
        let centeredBackground = croppedBackground.transformed(by: CGAffineTransform(translationX: -croppedBackground.extent.origin.x, y: -croppedBackground.extent.origin.y))
        
        return foreground?.composited(over: centeredBackground) ?? centeredBackground
    }
    
    private func compositeWithBackgroundForAVCapture(
        foreground: CIImage?,
        background: CIImage,
        size: CGSize,
        videoOrientation: AVCaptureVideoOrientation
    ) -> CIImage {
        // Apply orientation to background based on AVCaptureVideoOrientation
        let rotatedBackground = self.applyOrientationToBackground(background, orientation: videoOrientation)
        
        // Scale background to fill frame (aspect fill)
        let scaleX = size.width / rotatedBackground.extent.width
        let scaleY = size.height / rotatedBackground.extent.height
        let fillScale = max(scaleX, scaleY)
        
        let scaledBackground = rotatedBackground.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        
        // Center and crop background
        let offsetX = (scaledBackground.extent.width - size.width) / 2
        let offsetY = (scaledBackground.extent.height - size.height) / 2
        let cropRect = CGRect(x: offsetX, y: offsetY, width: size.width, height: size.height)
        let croppedBackground = scaledBackground.cropped(to: cropRect)
        let centeredBackground = croppedBackground.transformed(by: CGAffineTransform(translationX: -croppedBackground.extent.origin.x, y: -croppedBackground.extent.origin.y))
        
        return foreground?.composited(over: centeredBackground) ?? centeredBackground
    }
    
    private func applyOrientationToBackground(_ background: CIImage, orientation: AVCaptureVideoOrientation) -> CIImage {
        switch orientation {
        case .portrait:
            return background
        case .portraitUpsideDown:
            return background.oriented(.downMirrored)
        case .landscapeLeft:
            return background.oriented(.leftMirrored)
        case .landscapeRight:
            return background.oriented(.rightMirrored)
        @unknown default:
            return background
        }
    }
    
    private func compositeWithBlurredBackground(
        foreground: CIImage?,
        fullPixelBuffer: CVPixelBuffer,
        frameSize: CGSize
    ) -> CIImage {
        let backgroundImage = CIImage(cvPixelBuffer: fullPixelBuffer)
        
        // Clear cached blur if frame size changed significantly
        if abs(frameSize.width - lastFrameSize.width) > 10 || abs(frameSize.height - lastFrameSize.height) > 10 {
            cachedBlurredBackground = nil
        }
        
        cachedBlurredBackground = self.createBlurredImage(from: backgroundImage,
                                                          radius: blurRadius)
        
        guard let blurredBackground = cachedBlurredBackground else {
            return foreground ?? CIImage(color: .black)
        }
        
        return foreground?.composited(over: blurredBackground) ?? blurredBackground
    }
    
    
    private func applyRotationToBackground(_ background: CIImage, rotation: RTCVideoRotation) -> CIImage {
        #if os(macOS)
        return background.oriented(.upMirrored)
        #elseif os(iOS)
        switch rotation {
        case ._90:
            return background.oriented(.leftMirrored)
        case ._180:
            return background.oriented(.downMirrored)
        default:
            return background
        }
        #endif
    }
    
    private func createBlurredImage(from image: CIImage, radius: Float) -> CIImage? {
        guard let filter = gaussianBlurFilter else { return nil }
        
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        
        return filter.outputImage
    }
    
    private func convertPixelBufferToRTCVideoFrame(
        _ pixelBuffer: CVPixelBuffer,
        rotation: RTCVideoRotation,
        timeStampNs: Int64
    ) -> RTCVideoFrame? {
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        return RTCVideoFrame(buffer: rtcPixelBuffer, rotation: rotation, timeStampNs: timeStampNs)
    }
    
    private func convertRTCVideoFrameToPixelBuffer(_ rtcVideoFrame: RTCVideoFrame) -> CVPixelBuffer? {
        guard let rtcPixelBuffer = rtcVideoFrame.buffer as? RTCCVPixelBuffer else {
            print("Error: RTCVideoFrame buffer is not of type RTCCVPixelBuffer")
            return nil
        }
        return rtcPixelBuffer.pixelBuffer
    }
}

extension RTCVirtualBackground {
    func createSampleBufferFrom(pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var newSampleBuffer: CMSampleBuffer?
        var formatDescription: CMVideoFormatDescription?
        
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let formatDesc = formatDescription else { return nil }
        
        var timingInfo = CMSampleTimingInfo()
        timingInfo.duration = CMSampleBufferGetDuration(sampleBuffer)
        timingInfo.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        timingInfo.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )
        
        guard let newSampleBuffer else {
            print("Cannot create sample buffer")
            return nil
        }
        
        return newSampleBuffer
    }
}
