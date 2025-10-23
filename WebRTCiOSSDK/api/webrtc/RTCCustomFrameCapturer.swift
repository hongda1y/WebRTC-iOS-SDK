//
//  RTCCustomFrameCapturer.swift
//  WebRTCiOSSDK
//
//  Created by mekya on 27.09.2020.
//  Copyright © 2020 AntMedia. All rights reserved.
//

import Foundation
import WebRTC
import ReplayKit
import UIKit
import CoreMotion

class RTCCustomFrameCapturer: RTCVideoCapturer {
    
    let kNanosecondsPerSecond: Float64 = 1000000000
    var nanoseconds: Float64 = 0
    var lastSentFrameTimeStampNanoSeconds: Int64 = 0
    private var targetHeight: Int
        
    private var videoEnabled: Bool = true
    private var audioEnabled: Bool = true

    private weak var webRTCClient: WebRTCClient?
    
    private var frameRateIntervalNanoSeconds : Float64 = 0
    
    // if externalCapture is true, it means that capture method is called from an external component.
    // externalComponent is the BroadcastExtension
    private var externalCapture: Bool

    private var fps: Int
    
    // Motion manager for orientation detection when in background
    private let motionManager = CMMotionManager()
    private var currentOrientation: RTCVideoRotation = ._0
    private var isAppInBackground: Bool = false
    
    init(delegate: RTCVideoCapturerDelegate, height: Int, externalCapture: Bool = false, videoEnabled: Bool = true, audioEnabled: Bool = false, fps: Int = 30)
    {
        self.targetHeight = height
        self.externalCapture = externalCapture;
        
        //if external capture is enabled videoEnabled and audioEnabled are ignored
        self.videoEnabled = videoEnabled
        self.audioEnabled = audioEnabled
        self.frameRateIntervalNanoSeconds = kNanosecondsPerSecond/Double(fps)
        self.fps = fps
            
        super.init(delegate: delegate)
        
        setupOrientationMonitoring()
    }
    
    deinit {
        stopOrientationMonitoring()
    }
    
    private func setupOrientationMonitoring() {
        // Monitor app state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Start device motion updates for background orientation detection
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.2
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let self = self, let motion = motion, self.isAppInBackground else { return }
                self.updateOrientationFromMotion(motion)
            }
        }
    }
    
    private func stopOrientationMonitoring() {
        NotificationCenter.default.removeObserver(self)
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }
    
    @objc private func appDidEnterBackground() {
        isAppInBackground = true
    }
    
    @objc private func appWillEnterForeground() {
        isAppInBackground = false
    }
    
    private func updateOrientationFromMotion(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        
        // Determine orientation based on gravity vector
        let angle = atan2(gravity.x, gravity.y)
        
        if angle >= -0.75 && angle <= 0.75 {
            // Portrait
            currentOrientation = ._0
        } else if angle >= 0.75 && angle <= 2.25 {
            // Landscape Left
            currentOrientation = ._270
        } else if angle >= -2.25 && angle <= -0.75 {
            // Landscape Right
            currentOrientation = ._90
        } else {
            // Portrait Upside Down
            currentOrientation = ._180
        }
    }
    
    private func getCurrentOrientation() -> RTCVideoRotation {
        if isAppInBackground {
            // Use motion-based orientation when in background
            return currentOrientation
        } else {
            // Use UIDevice orientation when in foreground
            switch UIDevice.current.orientation {
            case .portrait:
                return ._0
            case .portraitUpsideDown:
                return ._180
            case .landscapeLeft:
                return ._90
            case .landscapeRight:
                return ._270
            default:
                return currentOrientation // Fallback to last known orientation
            }
        }
    }
    
    public func setWebRTCClient(webRTCClient: WebRTCClient) {
        self.webRTCClient = webRTCClient
    }
    
    public func capture(_ pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation, timeStampNs: Int64)
    {
        if ((Double(timeStampNs) - Double(lastSentFrameTimeStampNanoSeconds)) < frameRateIntervalNanoSeconds ) {
            print("AntMediaSDK[verbose]: Dropping frame because high fps than the configured fps: \(fps). Incoming timestampNs:\(timeStampNs) last sent timestampNs:\(lastSentFrameTimeStampNanoSeconds) frameRateIntervalNs:\(frameRateIntervalNanoSeconds)")
            return
        }
        
        // Use provided rotation or detect current orientation
        var finalRotation = rotation
        
        // If rotation is default (0), detect the actual orientation
        // This is especially important when app is in background
        if rotation == ._0 {
            finalRotation = getCurrentOrientation()
        }
        
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        
        let rtcVideoFrame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: finalRotation,
            timeStampNs: Int64(timeStampNs)
        )
        
        self.delegate?.capturer(self, didCapture: rtcVideoFrame.newI420())
        lastSentFrameTimeStampNanoSeconds = Int64(timeStampNs)
    }
    
    public func capture(_ sampleBuffer: CMSampleBuffer, externalRotation: Int = -1) {
        if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 || !CMSampleBufferIsValid(sampleBuffer) ||
            !CMSampleBufferDataIsReady(sampleBuffer)) {
            NSLog("Buffer is not ready and dropping")
            return
        }
        
        let timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) *
            kNanosecondsPerSecond
                
        if ((Double(timeStampNs) - Double(lastSentFrameTimeStampNanoSeconds)) < frameRateIntervalNanoSeconds ) {
            print("AntMediaSDK[verbose]: Dropping frame because high fps than the configured fps: \(fps). Incoming timestampNs:\(timeStampNs) last sent timestampNs:\(lastSentFrameTimeStampNanoSeconds) frameRateIntervalNs:\(frameRateIntervalNanoSeconds)")
            return
        }
        
        let _pixelBuffer: CVPixelBuffer? = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        if let pixelBuffer = _pixelBuffer {
            var rotation = RTCVideoRotation._0
            
            if externalRotation == -1 {
                // Try to get orientation from sample buffer metadata
                if #available(iOS 11.0, *) {
                    if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                        let orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value)
                        switch orientation {
                        case .up:
                            rotation = RTCVideoRotation._0
                        case .down:
                            rotation = RTCVideoRotation._180
                        case .left:
                            rotation = RTCVideoRotation._90
                        case .right:
                            rotation = RTCVideoRotation._270
                        default:
                            NSLog("orientation NOT FOUND, using detected orientation")
                            rotation = getCurrentOrientation()
                        }
                    } else {
                        NSLog("CANNOT get image rotation from metadata, using detected orientation")
                        rotation = getCurrentOrientation()
                    }
                } else {
                    NSLog("CANNOT get image rotation because iOS version is older than 11")
                    rotation = getCurrentOrientation()
                }
            } else {
                rotation = RTCVideoRotation(rawValue: externalRotation) ?? RTCVideoRotation._0
            }
            
            capture(pixelBuffer, rotation: rotation, timeStampNs: Int64(timeStampNs))
        } else {
            NSLog("Cannot get image buffer")
        }
    }
    
    public func startCapture() {
        if !externalCapture {
            let recorder = RPScreenRecorder.shared()
           
            if #available(iOS 11.0, *) {
                recorder.startCapture { [weak self] buffer, bufferType, error in
                    guard let self = self else { return }
                    
                    if bufferType == RPSampleBufferType.video && self.videoEnabled {
                        self.capture(buffer)
                    } else if bufferType == RPSampleBufferType.audioApp && self.audioEnabled {
                        self.webRTCClient?.deliverExternalAudio(sampleBuffer: buffer)
                    }
                } completionHandler: { (error) in
                    guard error == nil else {
                        print("Screen capturer is not started")
                        return
                    }
                }
            }
        }
    }
    
    public func stopCapture() {
        if !externalCapture {
            let recorder = RPScreenRecorder.shared()
            if recorder.isRecording {
                if #available(iOS 11.0, *) {
                    recorder.stopCapture { error in
                        guard error == nil else {
                            print("Cannot stop capture \(String(describing: error))")
                            return
                        }
                    }
                }
            }
        }
    }
}
