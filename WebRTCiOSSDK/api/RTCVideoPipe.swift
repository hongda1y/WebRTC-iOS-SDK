//
//  RTCVideoPipe.swift
//  WebRTCiOSSDK
//
//  Created by Socheat on 27/5/25.
//  Optimized version with performance improvements
//

import Foundation
import WebRTC
import os.log

@objc public class RTCVideoPipe: NSObject, RTCVideoCapturerDelegate {
    
    // MARK: - Properties
    private let virtualBackground: RTCVirtualBackground
    private weak var videoSource: RTCVideoSource?
    private let processingQueue = DispatchQueue(label: "com.webrtc.videopipe", qos: .userInteractive)
    
    // Thread-safe properties using atomic operations
    private let atomicTimestamp = AtomicInt64()
    private let atomicLastProcessed = AtomicInt64()
    private let atomicFrameCount = AtomicInt64()
    
    // Configuration
    private var targetFPS: Int = 15 {
        didSet {
            fpsInterval = Int64(1_000_000_000 / targetFPS)
        }
    }
    private var fpsInterval: Int64
    
    // Background image with thread-safe access
    private let backgroundImageLock = NSLock()
    private var _backgroundImage: UIImage?
    private var backgroundImage: UIImage? {
        get {
            backgroundImageLock.lock()
            defer { backgroundImageLock.unlock() }
            return _backgroundImage
        }
        set {
            backgroundImageLock.lock()
            _backgroundImage = newValue
            backgroundImageLock.unlock()
        }
    }
    
    // Performance tracking
    private var isProcessingFrame = false
    private let processingLock = NSLock()
    
    // Logging
    private static let logger = OSLog(subsystem: "com.webrtc.sdk", category: "VideoPipe")
    
    // MARK: - Initialization
    @objc public init(videoSource: RTCVideoSource) {
        self.videoSource = videoSource
        self.virtualBackground = RTCVirtualBackground()
        self.fpsInterval = Int64(1_000_000_000 / 15) // 15 fps default
        
        super.init()
        
        os_log("RTCVideoPipe initialized with target FPS: %d", log: Self.logger, type: .info, targetFPS)
    }
    
    // MARK: - Public Methods
    @objc public func setBackgroundImage(image: UIImage?) {
        virtualBackground.clearBackgroundImage()
        backgroundImage = image
        os_log("Background image updated", log: Self.logger, type: .debug)
    }
    
    @objc public func setTargetFPS(_ fps: Int) {
        guard fps > 0 && fps <= 60 else {
            os_log("Invalid FPS value: %d. Must be between 1-60", log: Self.logger, type: .error, fps)
            return
        }
        
        targetFPS = fps
        os_log("Target FPS updated to: %d", log: Self.logger, type: .info, fps)
    }
    
    @objc public func getProcessingStats() -> [String: Any] {
        return [
            "totalFramesProcessed": atomicFrameCount.value,
            "lastProcessedTimestamp": atomicLastProcessed.value,
            "latestTimestamp": atomicTimestamp.value,
            "targetFPS": targetFPS,
            "isCurrentlyProcessing": isProcessingFrame
        ]
    }
    
    // MARK: - RTCVideoCapturerDelegate
    @objc public func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        let currentTimestamp = frame.timeStampNs
        let lastProcessed = atomicLastProcessed.value
        
        // Quick timestamp check before expensive processing
        let elapsedTime = currentTimestamp - lastProcessed
        guard elapsedTime >= fpsInterval else {
            // Skip frame - too frequent
            return
        }
        
        // Check if we're already processing a frame to prevent queue buildup
        processingLock.lock()
        guard !isProcessingFrame else {
            processingLock.unlock()
            os_log("Skipping frame - already processing", log: Self.logger, type: .debug)
            return
        }
        isProcessingFrame = true
        processingLock.unlock()
        
        // Get current background image atomically
        let currentBackgroundImage = backgroundImage
        
        // Process frame asynchronously
        virtualBackground.processForegroundMask(
            from: frame,
            backgroundImage: currentBackgroundImage
        ) { [weak self] processedFrame, error in
            
            guard let self = self else { return }
            
            // Reset processing flag
            self.processingLock.lock()
            self.isProcessingFrame = false
            self.processingLock.unlock()
            
            if let error = error {
                os_log("Error processing frame: %{public}@", log: Self.logger, type: .error, error.localizedDescription)
                // Fallback: pass through original frame
                self.emitFrame(frame, from: capturer, originalTimestamp: currentTimestamp)
                return
            }
            
            guard let processedFrame = processedFrame else {
                os_log("Processed frame is nil", log: Self.logger, type: .error)
                // Fallback: pass through original frame
                self.emitFrame(frame, from: capturer, originalTimestamp: currentTimestamp)
                return
            }
            
            self.emitFrame(processedFrame, from: capturer, originalTimestamp: currentTimestamp)
        }
    }
    
    // MARK: - Private Methods
    private func emitFrame(_ frame: RTCVideoFrame, from capturer: RTCVideoCapturer, originalTimestamp: Int64) {
        // Thread-safe timestamp checking and updating
        let latestTimestamp = atomicTimestamp.value
        
        // Ensure frame ordering
        guard frame.timeStampNs > latestTimestamp else {
            os_log("Dropping out-of-order frame: %lld <= %lld", log: Self.logger, type: .debug, frame.timeStampNs, latestTimestamp)
            return
        }
        
        // Update atomic values
        atomicTimestamp.store(frame.timeStampNs)
        atomicLastProcessed.store(originalTimestamp)
        atomicFrameCount.increment()
        
        // Emit frame on main thread if needed, or directly if we're already on appropriate thread
        if Thread.isMainThread {
            videoSource?.capturer(capturer, didCapture: frame)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.videoSource?.capturer(capturer, didCapture: frame)
            }
        }
        
        // Log performance metrics periodically
        let frameCount = atomicFrameCount.value
        if frameCount % 100 == 0 {
            os_log("Processed %lld frames", log: Self.logger, type: .info, frameCount)
        }
    }
}

// MARK: - Thread-Safe Atomic Operations
private class AtomicInt64 {
    private var _value: Int64 = 0
    private let lock = NSLock()
    
    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    
    func store(_ newValue: Int64) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
    
    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
    
    func compareAndSwap(expected: Int64, desired: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if _value == expected {
            _value = desired
            return true
        }
        return false
    }
}
