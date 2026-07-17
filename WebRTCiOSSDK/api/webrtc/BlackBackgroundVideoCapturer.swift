/*
 * Custom Black Background Video Capturer
 * Used when camera permissions are denied
 */

import AVFoundation
import CoreMedia
import UIKit
import WebRTC

final class BlackBackgroundVideoCapturer: RTCVideoCapturer {
    
    // MARK: - Properties
    
    private let captureQueue: DispatchQueue
    private var displayLink: CADisplayLink?
    private var isCapturing = false
    
    private let width: Int32
    private let height: Int32
    private let fps: Int
    
    private var pixelBuffer: CVPixelBuffer?
    
    // MARK: - Initialization
    
    init(delegate: RTCVideoCapturerDelegate, width: Int32 = 320, height: Int32 = 240, fps: Int = 15) {
        self.width = width
        self.height = height
        self.fps = fps
        self.captureQueue = DispatchQueue(
            label: "org.webrtc.blackbackgroundcapturer",
            qos: .userInitiated
        )
        
        super.init(delegate: delegate)
        
        createBlackPixelBuffer()
    }
    
    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    // MARK: - Public API
    
    func startCapture() {
        captureQueue.async { [weak self] in
            guard let self = self, !self.isCapturing else { return }
            
            self.isCapturing = true
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.displayLink = CADisplayLink(target: self, selector: #selector(self.generateFrame))
                self.displayLink?.preferredFramesPerSecond = self.fps
                self.displayLink?.add(to: .main, forMode: .common)
            }
        }
    }
    
    func stopCapture() {
        captureQueue.async { [weak self] in
            guard let self = self, self.isCapturing else { return }
            
            self.isCapturing = false
            
            DispatchQueue.main.async { [weak self] in
                self?.displayLink?.invalidate()
                self?.displayLink = nil
            }
        }
    }
    
    // MARK: - Private Implementation
    
    private func createBlackPixelBuffer() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("Failed to create black pixel buffer")
            return
        }
        
        // Fill with black (Y=0, Cb=128, Cr=128 for YUV)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        // Fill Y plane with 0 (black)
        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let ySize = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * Int(height)
            memset(yPlane, 0, ySize)
        }
        
        // Fill UV plane with 128 (neutral chroma)
        if let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let uvSize = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * Int(height / 2)
            memset(uvPlane, 128, uvSize)
        }
        
        self.pixelBuffer = buffer
    }
    
    @objc private func generateFrame() {
        guard isCapturing, let pixelBuffer = pixelBuffer else { return }
        
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs = Int64(CACurrentMediaTime() * 1_000_000_000)
        
        let videoFrame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: ._0,
            timeStampNs: timeStampNs
        )
        
        delegate?.capturer(self, didCapture: videoFrame)
    }
}
