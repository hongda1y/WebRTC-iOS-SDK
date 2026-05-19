//
//  WebRTCClient.swift
//  AntMediaSDK
//
//  Copyright © 2018 AntMedia. All rights reserved.
//

import Foundation
import AVFoundation
import WebRTC
import ReplayKit
import Network

class WebRTCClient: NSObject {
    
    
    let VIDEO_TRACK_ID = "VIDEO"
    let AUDIO_TRACK_ID = "AUDIO"
    let LOCAL_MEDIA_STREAM_ID = "STREAM"
    
    private var audioDeviceModule: RTCAudioDeviceModule? = nil;
    private var factory: RTCPeerConnectionFactory? = nil;
    
    weak var delegate: WebRTCClientDelegate?
    var peerConnection : RTCPeerConnection?
    
    private var videoCapturer: RTCVideoCapturer?
    private var pipe: RTCVideoPipe?
    
    var localVideoTrack: RTCVideoTrack! {
        didSet {
            if let localVideoTrack {
                delegate?.onLocalTrackUpdate(track: localVideoTrack)
            }
        }
    }
    
    public var localAudioTrack: RTCAudioTrack!
    public var remoteVideoTrack: RTCVideoTrack!
    public var remoteAudioTrack: RTCAudioTrack!
    public var remoteVideoView: RTCVideoRenderer?
    public var localVideoView: RTCVideoRenderer?
    var videoSender: RTCRtpSender?
    var dataChannel: RTCDataChannel?
    
    private var rtcFileName: String = ""
    
    private var token: String!
    private var streamId: String!
    
    private var audioEnabled: Bool = true
    private var videoEnabled: Bool = true
    /**
     If useExternalCameraSource is false, it opens the local camera
     If it's true, it does not open the local camera. When it's set to true, it can record the screen in-app or you can give external frames through your application or BroadcastExtension. If you give external frames or through BroadcastExtension, you need to set the externalVideoCapture to true as well
     */
    private var useExternalCameraSource: Bool = false;
    
    private var videoEffect: VideoEffect? = nil
    
    private var enableDataChannel: Bool = false;
    
    private(set) var cameraPosition: AVCaptureDevice.Position = .front
    
    private var targetWidth: Int = 480
    private var targetHeight: Int = 360
    
    // Add to your private properties (near targetHeight, etc.):
    private var screenShareTargetHeight: Int = 1280
    
    private var externalVideoCapture: Bool = false;
    
    private var externalAudio: Bool = false;
    
    private var cameraSourceFPS: Int = 30;
    
    private var isInitiatorp2p: Bool = false
    /*
     State of the connection
     */
    var iceConnectionState:RTCIceConnectionState = .new;
    
    /// Adapts video bitrate / fps / resolution to network + device conditions.
    /// Created when local media is added, torn down on disconnect.
    private var adaptiveStreamer: AdaptiveVideoStreamer?

    /// Caller's explicit `setMaxVideoBps` value, if any. Acts as a hard
    /// ceiling that the adaptive streamer must respect.
    private var maxVideoBpsCeiling: NSNumber?
    
    
    private var degradationPreference:RTCDegradationPreference = .maintainResolution;
    
    public init(remoteVideoView: RTCVideoRenderer?, localVideoView: RTCVideoRenderer?, delegate: WebRTCClientDelegate, externalAudio:Bool) {
        super.init()
        
        self.remoteVideoView = remoteVideoView
        self.localVideoView = localVideoView
        self.delegate = delegate
        
        RTCPeerConnectionFactory.initialize()
        
        self.externalAudio = externalAudio;
        self.audioDeviceModule = RTCAudioDeviceModule();
        self.audioDeviceModule?.setExternalAudio(externalAudio)
        
        factory = initFactory()
        
        let stunServer = Config.defaultStunServer()
        let defaultConstraint = Config.createDefaultConstraint()
        let configuration = Config.createConfiguration(server: stunServer)
        
        self.peerConnection = factory?.peerConnection(with: configuration, constraints: defaultConstraint, delegate: self)
    }
    
    public convenience init(remoteVideoView: RTCVideoRenderer?, localVideoView: RTCVideoRenderer?, delegate: WebRTCClientDelegate, mode: AntMediaClientMode, cameraPosition: AVCaptureDevice.Position, targetWidth: Int, targetHeight: Int, streamId: String) {
        self.init(remoteVideoView: remoteVideoView, localVideoView: localVideoView, delegate: delegate,
                  mode: mode, cameraPosition: cameraPosition, targetWidth: targetWidth, targetHeight: targetHeight, videoEnabled: true, enableDataChannel:false, streamId: streamId)
    }
    public convenience init(remoteVideoView: RTCVideoRenderer?, localVideoView: RTCVideoRenderer?, delegate: WebRTCClientDelegate, mode: AntMediaClientMode, cameraPosition: AVCaptureDevice.Position, targetWidth: Int, targetHeight: Int, videoEnabled: Bool, enableDataChannel: Bool, streamId: String) {
        self.init(remoteVideoView: remoteVideoView, localVideoView: localVideoView, delegate: delegate,
                  mode: mode, cameraPosition: cameraPosition, targetWidth: targetWidth, targetHeight: targetHeight, videoEnabled: true, enableDataChannel:false, useExternalCameraSource: false, streamId: streamId)
    }
    
    public convenience init(remoteVideoView: RTCVideoRenderer?, localVideoView: RTCVideoRenderer?, delegate: WebRTCClientDelegate, mode: AntMediaClientMode, cameraPosition: AVCaptureDevice.Position, targetWidth: Int, targetHeight: Int, videoEnabled: Bool, enableDataChannel: Bool, useExternalCameraSource: Bool, videoEffect: VideoEffect? = nil, externalAudio: Bool = false, externalVideoCapture: Bool = false, cameraSourceFPS: Int = 30, streamId: String,
                            degradationPreference: RTCDegradationPreference = RTCDegradationPreference.maintainResolution, rtcFileName: String? = nil) {
        self.init(remoteVideoView: remoteVideoView, localVideoView: localVideoView, delegate: delegate, externalAudio: externalAudio)
        self.cameraPosition = cameraPosition
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.videoEnabled = videoEnabled
        self.useExternalCameraSource = useExternalCameraSource;
        self.videoEffect = videoEffect
        self.enableDataChannel = enableDataChannel;
        self.externalVideoCapture = externalVideoCapture;
        self.cameraSourceFPS = cameraSourceFPS;
        self.streamId = streamId;
        self.degradationPreference = degradationPreference
        self.rtcFileName = rtcFileName ?? ""
        
        if (mode != .play) {
            self.addLocalMediaStream()
        }
    }
    
    public func externalVideoCapture(externalVideoCapture: Bool) {
        self.externalVideoCapture = externalVideoCapture;
    }
    
    private func initFactory() -> RTCPeerConnectionFactory {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        
        if (audioDeviceModule == nil) {
            return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        }
        else {
            return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory,
                                            audioDeviceModule: audioDeviceModule!)
        }
    }
    
//    public func setMaxVideoBps(maxVideoBps:NSNumber) {
//        printf("In setMaxVideoBps:\(maxVideoBps)")
//        if (maxVideoBps.intValue > 0) {
//            printf("setMaxVideoBps:\(maxVideoBps)")
//            self.peerConnection?.setBweMinBitrateBps(nil, currentBitrateBps: nil, maxBitrateBps: maxVideoBps)
//        }
//    }
    public func setMaxVideoBps(maxVideoBps: NSNumber) {
        printf("In setMaxVideoBps:\(maxVideoBps)")
        guard maxVideoBps.intValue > 0 else { return }

        printf("setMaxVideoBps:\(maxVideoBps)")
        self.peerConnection?.setBweMinBitrateBps(nil,
                                                 currentBitrateBps: nil,
                                                 maxBitrateBps: maxVideoBps)

        // Remember the caller's cap and push it into the streamer so its
        // adaptive profiles never exceed it.
        self.maxVideoBpsCeiling = maxVideoBps
        self.adaptiveStreamer?.bitrateCeilingBps = maxVideoBps.intValue
    }
    
    public func getStats(handler: @escaping (RTCStatisticsReport) -> Void) {
        peerConnection?.statistics(completionHandler: handler)
    }
    
    public func setStreamId(_ streamId: String) {
        self.streamId = streamId
    }
    
    public func setToken(_ token: String) {
        self.token = token
    }
    
    public func setRemoteDescription(_ description: RTCSessionDescription, completionHandler: @escaping RTCSetSessionDescriptionCompletionHandler) {
        peerConnection?.setRemoteDescription(description, completionHandler: completionHandler)
    }
    
    public func addCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate)
    }
    
    public func sendData(data: Data, binary: Bool = false) {
        if dataChannel?.readyState == .open {
            let dataBuffer = RTCDataBuffer.init(data: data, isBinary: binary)
            dataChannel?.sendData(dataBuffer)
        } else {
            printf("Data channel is nil or state is not open. State is \(String(describing: self.dataChannel?.readyState)) Please check that data channel is enabled in server side ")
        }
    }
    
    public func isDataChannelActive() -> Bool {
        dataChannel?.readyState == .open
    }
    
    
    public func sendAnswer() {
        let constraint = Config.createAudioVideoConstraints()
        peerConnection?.answer(for: constraint, completionHandler: { [weak self] sdp, error in
            guard let self else { return }
            
            if error != nil {
                printf("Error (sendAnswer): " + error!.localizedDescription)
            } else {
                printf("Got your answer")
                if sdp?.type == RTCSdpType.answer {
                    
                    peerConnection?.setLocalDescription(sdp!, completionHandler: { [weak self] error in
                        if error != nil {
                            self?.printf("Error (sendAnswer/closure): " + error!.localizedDescription)
                        }
                    })
                    
                    var answerDict = [String: Any]()
                    
                    if token.isEmpty {
                        answerDict =  ["type": "answer",
                                       "command": "takeConfiguration",
                                       "sdp": sdp!.sdp,
                                       "streamId": self.streamId!] as [String : Any]
                    } else {
                        answerDict =  ["type": "answer",
                                       "command": "takeConfiguration",
                                       "sdp": sdp!.sdp,
                                       "streamId": streamId ?? "",
                                       "token": token ?? ""] as [String : Any]
                    }
                    
                    delegate?.sendMessage(answerDict)
                }
            }
        })
    }
    
    public func createOffer() {
        
        //let the one who creates offer also create data channel.
        //by doing that it will work both in publish-play and peer-to-peer mode
        if enableDataChannel {
            dataChannel = createDataChannel()
            dataChannel?.delegate = self
        }
        
        let constraint = Config.createAudioVideoConstraints()
        
        peerConnection?.offer(for: constraint, completionHandler: { [weak self] sdp, error in
            guard let self else { return }
            
            if sdp?.type == RTCSdpType.offer {
                printf("Got your offer")
                
                peerConnection?.setLocalDescription(sdp!, completionHandler: { [weak self] error in
                    if error != nil {
                        self?.printf("Error (createOffer): " + error!.localizedDescription)
                    }
                })
                
                printf("offer sdp: " + sdp!.sdp)
                var offerDict = [String: Any]()
                
                if token.isEmpty {
                    offerDict =  ["type": "offer",
                                  "command": "takeConfiguration",
                                  "sdp": sdp!.sdp,
                                  "streamId": self.streamId!] as [String : Any]
                } else {
                    offerDict =  ["type": "offer",
                                  "command": "takeConfiguration",
                                  "sdp": sdp!.sdp,
                                  "streamId": streamId ?? "",
                                  "token": token ?? ""] as [String : Any]
                }
                
                isInitiatorp2p = true
                delegate?.sendMessage(offerDict)
            }
        })
    }
    
    private func createOfferWithIceRestart(streamId: String) {
        let constraint = Config.createAudioVideoConstraintsForRestart()
        
        peerConnection?.offer(for: constraint, completionHandler: { [weak self] sdp, error in
            guard let self = self else { return }
            
            if let error = error {
                printf("Error creating offer for ICE restart: \(error.localizedDescription)")
                return
            }
            
            guard let sdp = sdp else { return }
            
            peerConnection?.setLocalDescription(sdp, completionHandler: { [weak self] error in
                if let error = error {
                    self?.printf("Error setting local description for ICE restart: \(error.localizedDescription)")
                    return
                }
                
                // Send the new offer with ICE restart flag
                self?.sendIceRestartOffer(sdp: sdp, streamId: streamId)
            })
        })
    }

    // 4. Send ICE restart offer through signaling
    private func sendIceRestartOffer(sdp: RTCSessionDescription, streamId: String) {
        var offerDict = [String: Any]()
        
        if token.isEmpty {
            offerDict = ["type": "offer",
                         "command": "takeConfiguration",
                         "sdp": sdp.sdp,
                         "streamId": streamId,
                         "iceRestart": true] as [String : Any]
        } else {
            offerDict = ["type": "offer",
                         "command": "takeConfiguration",
                         "sdp": sdp.sdp,
                         "streamId": streamId,
                         "token": token ?? "",
                         "iceRestart": true] as [String : Any]
        }
        
        delegate?.sendMessage(offerDict)
        printf("Sent ICE restart offer for stream: \(streamId)")
    }
    
    public func restartICE() {
        if iceConnectionState == .failed {
//            peerConnection?.restartIce()
            if isInitiatorp2p {
                createOfferWithIceRestart(streamId: streamId)
            }
        }
    }
    
    public func stop() {
        disconnect()
    }
    
    private func createDataChannel() -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        guard let dataChannel = self.peerConnection?.dataChannel(forLabel: "WebRTCData", configuration: config) else {
            printf("Warning: Couldn't create data channel.")
            return nil
        }
        return dataChannel
    }
    
    public func disconnect() {
        printf("disconnecting and releasing resources for \(streamId)")
        //TODO: how to clear all resources
        
        // ── ADD: stop adaptive streaming first ──────────────────
        adaptiveStreamer?.stop()
        adaptiveStreamer = nil
        // ────────────────────────────────────────────────────────
        
        if let view = self.localVideoView {
            self.localVideoTrack?.remove(view)
        }
        
        if let view = self.remoteVideoView {
            self.remoteVideoTrack?.remove(view)
        }
        
        self.remoteVideoView?.renderFrame(nil)
        self.localVideoView?.renderFrame(nil)
        
        self.localVideoTrack = nil
        self.remoteVideoTrack = nil
        
        self.localAudioTrack = nil
        self.remoteAudioTrack = nil
        
        if self.videoCapturer is CustomCameraVideoCapturer {
            (self.videoCapturer as? CustomCameraVideoCapturer)?.stopCapture()
        } else if self.videoCapturer is RTCCustomFrameCapturer {
            (self.videoCapturer as? RTCCustomFrameCapturer)?.stopCapture()
        } else if self.videoCapturer is RTCFileVideoCapturer {
            (self.videoCapturer as? RTCFileVideoCapturer)?.stopCapture()
        } else if self.videoCapturer is BlackBackgroundVideoCapturer {
            (self.videoCapturer as? BlackBackgroundVideoCapturer)?.stopCapture()
        }
        
        self.videoCapturer = nil;
        
        self.pipe = nil
        
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        
        if let videoSender {
            self.peerConnection?.removeTrack(videoSender)
            self.videoSender = nil
        }
        
        self.peerConnection?.delegate = nil
        self.peerConnection?.close()
        self.peerConnection = nil;
        
        self.audioDeviceModule?.setExternalAudio(false)
        self.audioDeviceModule = nil
        
        printf("disconnected and released resources for \(streamId)")
    }
    
    public func toggleAudioEnabled() {
        setAudioEnabled(enabled: !audioEnabled)
    }
    
    public func setAudioEnabled(enabled:Bool) {
        self.audioEnabled = enabled;
        if localAudioTrack != nil {
            localAudioTrack.isEnabled = audioEnabled
        }
    }
    
    public func isAudioEnabled() -> Bool { audioEnabled }
    
    public func toggleVideoEnabled() {
        self.setVideoEnabled(enabled: !self.videoEnabled)
    }
    
    func isVideoEnabled() -> Bool {
        return self.videoEnabled;
    }
    
    public func isScreenShare() -> Bool { useExternalCameraSource }
    
    public func setVideoEnabled(enabled:Bool){
        self.videoEnabled = enabled
        
        if !enabled {
            if let capturer = videoCapturer as? CustomCameraVideoCapturer {
                capturer.stopCapture()
            }
        } else {
            startCapture()
        }
    }
    
    public func getIceConnectionState() -> RTCIceConnectionState {
        return iceConnectionState;
    }
    
    @discardableResult
    private func startCapture() -> Bool {
        
        if let fileCapturer = videoCapturer as? RTCFileVideoCapturer {

            // RTCFileVideoCapturer requires the file to be in the main bundle,
            // mp4-wrapped, H.264 video, no audio, yuv420p pixel format. If the
            // file is missing or wrongly encoded, the error will say so.
            guard !rtcFileName.isEmpty else {
                printf("RTCFileVideoCapturer: rtcFileName is empty — call setRTCFile(name:) first or rely on the simulator default.")
                return false
            }

            // Sanity-check that the file actually shipped with the app, and surface
            // a clear log instead of a silent failure deep inside WebRTC.
            let fileStem = (rtcFileName as NSString).deletingPathExtension
            let fileExt  = (rtcFileName as NSString).pathExtension.isEmpty
                ? "mp4"
                : (rtcFileName as NSString).pathExtension

            if Bundle.main.url(forResource: fileStem, withExtension: fileExt) == nil {
                printf("RTCFileVideoCapturer: '\(rtcFileName)' not found in main bundle. "
                       + "Add it to the app target's 'Copy Bundle Resources' build phase.")
                return false
            }

            fileCapturer.startCapturing(fromFileNamed: rtcFileName) { [weak self] error in
                // Capturer loops the file internally; this closure fires on errors only.
                self?.printf("RTCFileVideoCapturer error: \(error.localizedDescription)")
            }

            printf("RTCFileVideoCapturer started — file=\(rtcFileName)")
            return true
        }
        
        if let blackCapturer = videoCapturer as? BlackBackgroundVideoCapturer {
            blackCapturer.startCapture()
            return true
        }
        
        let camera = CustomCameraVideoCapturer.captureDevices().first { $0.position == cameraPosition }
//        let camera = RTCCameraVideoCapturer.captureDevices().first { $0.position == cameraPosition }
        
        guard let camera else {
            printf("Not Camera Found")
            return false
        }
        
        let supportedFormats = CustomCameraVideoCapturer.supportedFormats(for: camera)
//        let supportedFormats = RTCCameraVideoCapturer.supportedFormats(for: camera)
        var currentDiff = INT_MAX
        var selectedFormat: AVCaptureDevice.Format? = nil
        for supportedFormat in supportedFormats {
            let dimension = CMVideoFormatDescriptionGetDimensions(supportedFormat.formatDescription)
            
            if dimension.width  == Int32(targetWidth) && dimension.height == Int32(targetHeight) {
                selectedFormat = supportedFormat
                break
            }
            
            let diff = abs(Int32(targetWidth) - dimension.width) + abs(Int32(targetHeight) - dimension.height);
            if (diff < currentDiff) {
                selectedFormat = supportedFormat
                currentDiff = diff
            }
        }
        
        guard let selectedFormat else {
            printf("Cannot open camera not suitable format")
            return false
        }
        
        var maxSupportedFramerate: Float64 = 0
        for fpsRange in selectedFormat.videoSupportedFrameRateRanges {
            maxSupportedFramerate = fmax(maxSupportedFramerate, fpsRange.maxFrameRate)
        }
        let fps = fmin(maxSupportedFramerate, Double(cameraSourceFPS))
        
        let dimension = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
        
        printf("Camera resolution: " + String(dimension.width) + "x" + String(dimension.height)
               + " fps: " + String(fps))
        
//        let cameraVideoCapturer = videoCapturer as? RTCCameraVideoCapturer
        let cameraVideoCapturer = videoCapturer as? CustomCameraVideoCapturer
    
        
        if #available(iOS 16.0, *) {
//            if cameraVideoCapturer?.captureSession.isMultitaskingCameraAccessSupported == true {
//                cameraVideoCapturer?.captureSession.isMultitaskingCameraAccessEnabled = true
//            }
        }
        
//        cameraVideoCapturer?.startCapture(with: camera,
//                                          format: selectedFormat,
//                                          fps: Int(fps))
        
        
        cameraVideoCapturer?.startCapture(with: camera,
                                          format: selectedFormat,
                                          fps: Int(fps))
        
        
        mirrorVideoTrack()
        
        return true
    }
    
    
    private func mirrorVideoTrack() {
        if let localVideoView = localVideoView as? RTCMTLVideoView {
//            if withAnimation {
//                UIView.animate(withDuration: 0.3) {
//                    localVideoView.alpha = 0
//                } completion: { _ in
//                    UIView.animate(withDuration: 0.3) {
//                        localVideoView.alpha = 1
//                    }
//                }
//                
//                UIView.transition(with: localVideoView, duration: 0.6, options: .transitionFlipFromLeft, animations: {
//                    if self.cameraPosition == .front {
//                        localVideoView.transform = CGAffineTransform(scaleX: -1, y: 1)
//                    } else {
//                        localVideoView.transform = .identity
//                    }
//                }, completion: nil)
//            } else {
                DispatchQueue.main.async { [weak self] in
                    if self?.cameraPosition == .front {
                        localVideoView.transform = CGAffineTransform(scaleX: -1, y: 1)
                    } else {
                        localVideoView.transform = .identity
                    }
                }
//            }
        }
    }
    
    // Add as a public setter so callers can tune per-device if needed:
    public func setScreenShareTargetHeight(_ height: Int) {
        self.screenShareTargetHeight = height
        printf("Screen-share target height set to \(height)")
    }
    
    private func createVideoTrack() -> RTCVideoTrack? {

        guard let factory else { return nil }

        if useExternalCameraSource {
            // (unchanged screencast path)
            let videoSource = factory.videoSource(forScreenCast: true)
            videoCapturer = RTCCustomFrameCapturer.init(
                delegate: videoSource,
                height: screenShareTargetHeight,
                externalCapture: externalVideoCapture,
                videoEnabled: videoEnabled,
                audioEnabled: externalAudio,
                fps: self.cameraSourceFPS
            )
            (videoCapturer as? RTCCustomFrameCapturer)?.setWebRTCClient(webRTCClient: self)
            (videoCapturer as? RTCCustomFrameCapturer)?.startCapture()
            return factory.videoTrack(with: videoSource, trackId: "video0")
        }

        let videoSource = factory.videoSource()

        #if targetEnvironment(simulator)

        // ── Simulator path: feed bundled sample file into the local pipeline ──
        printf("[Sim] Using RTCFileVideoCapturer for local source")

        // 1. Default the file name if the caller didn't set one.
        if rtcFileName.isEmpty {
            rtcFileName = "sample.mp4"
            printf("[Sim] rtcFileName defaulted to '\(rtcFileName)'")
        }

        // 2. Verify the file is actually in the bundle BEFORE handing off to
        //    WebRTC, so we get a clear error instead of a silent black preview.
        let stem = (rtcFileName as NSString).deletingPathExtension
        let ext  = (rtcFileName as NSString).pathExtension.isEmpty
            ? "mp4"
            : (rtcFileName as NSString).pathExtension

        guard let bundleURL = Bundle.main.url(forResource: stem, withExtension: ext) else {
            printf("[Sim] ❌ '\(rtcFileName)' NOT in main bundle. "
                   + "Add it to your app target's Copy Bundle Resources.")
            return nil
        }
        printf("[Sim] ✅ Found sample at \(bundleURL.path)")

        // 3. Apply video effects pipe if configured (matches camera path).
        let captureDelegate: RTCVideoCapturerDelegate
        if let videoEffect {
            pipe = RTCVideoPipe(videoSource: videoSource)
            switch videoEffect {
            case .blur:                   pipe?.setBackgroundImage(image: nil)
            case .image(let image):       pipe?.setBackgroundImage(image: image)
            }
            captureDelegate = pipe!
            printf("[Sim] Video effect pipe inserted")
        } else {
            captureDelegate = videoSource
        }

        // 4. Create the file capturer wired to whatever delegate we resolved.
        let fileCapturer = RTCFileVideoCapturer(delegate: captureDelegate)
        videoCapturer = fileCapturer

        // 5. Start capturing. The closure fires only on error; success is silent.
        fileCapturer.startCapturing(fromFileNamed: rtcFileName) { [weak self] error in
            self?.printf("[Sim] ❌ RTCFileVideoCapturer error: \(error.localizedDescription)")
        }
        printf("[Sim] startCapturing(fromFileNamed: \(rtcFileName)) issued")

        #else

        // ── Device path (unchanged camera flow) ─────────────────────────────
        let cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)

        if cameraPermissionStatus == .denied || cameraPermissionStatus == .restricted {
            printf("Camera permission denied or restricted. Using black background capturer.")
            videoCapturer = BlackBackgroundVideoCapturer(
                delegate: videoSource,
                width: Int32(targetWidth),
                height: Int32(targetHeight),
                fps: cameraSourceFPS
            )
        } else {
            if let videoEffect {
                pipe = nil
                pipe = RTCVideoPipe(videoSource: videoSource)
                switch videoEffect {
                case .blur:               pipe?.setBackgroundImage(image: nil)
                case .image(let image):   pipe?.setBackgroundImage(image: image)
                }
                videoCapturer = CustomCameraVideoCapturer(delegate: pipe!)
            } else {
                videoCapturer = CustomCameraVideoCapturer(delegate: videoSource)
            }
        }

        if isVideoEnabled() {
            let captureStarted = startCapture()
            if !captureStarted { return nil }
        }

        #endif

        // 6. Create the track on top of the source. Anything attached as a
        //    renderer to this track will receive frames from the file/camera.
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        return videoTrack
    }
    
//    private func createVideoTrack() -> RTCVideoTrack?  {
//        
//        guard let factory else { return nil }
//        
//        if useExternalCameraSource {
//            //try with screencast video source
//            let videoSource = factory.videoSource(forScreenCast: true)
//            videoCapturer = RTCCustomFrameCapturer.init(delegate: videoSource, height: targetHeight, externalCapture: externalVideoCapture, videoEnabled: videoEnabled, audioEnabled: externalAudio, fps:self.cameraSourceFPS);
//            
//            (videoCapturer as? RTCCustomFrameCapturer)?.setWebRTCClient(webRTCClient: self)
//            (videoCapturer as? RTCCustomFrameCapturer)?.startCapture()
//            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
//            return videoTrack
//        } else {
//            var videoSource = factory.videoSource()
//            #if targetEnvironment(simulator)
//            // Simulator has no real camera. Loop a bundled sample file instead so
//            // developers can still iterate on the call UI / signaling locally.
//            videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
//
//            // Fall back to a default sample file if the caller didn't set one.
//            // `sample.mp4` must be added to the app bundle (target membership ticked).
//            if rtcFileName.isEmpty {
//                rtcFileName = "sample.mp4"
//            }
//
//            let captureStarted = startCapture()
//            if !captureStarted {
//                printf("Simulator: failed to start RTCFileVideoCapturer with file=\(rtcFileName)")
//                return nil
//            }
//            #else
////#if targetEnvironment(simulator)
//////            videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
//////            let captureStarted = startCapture()
//////            if (!captureStarted) {
//////                return nil;
//////            }
////            
////#else
//            
//            // Check camera permission status
//            let cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
//            
//            if cameraPermissionStatus == .denied || cameraPermissionStatus == .restricted {
//                // Camera permission is denied - use black background capturer
//                printf("Camera permission denied or restricted. Using black background capturer.")
//                videoCapturer = BlackBackgroundVideoCapturer(
//                    delegate: videoSource,
//                    width: Int32(targetWidth),
//                    height: Int32(targetHeight),
//                    fps: cameraSourceFPS
//                )
//            } else {
//                
//                if let videoEffect {
//                    pipe = nil
//                    pipe = RTCVideoPipe(videoSource: videoSource)
//                    
//                    switch videoEffect {
//                    case .blur:
//                        pipe?.setBackgroundImage(image: nil)
//                    case .image(let image):
//                        pipe?.setBackgroundImage(image: image)
//                    }
//                    
//                    //                videoCapturer = RTCCameraVideoCapturer(delegate: pipe!)
//                    videoCapturer = CustomCameraVideoCapturer(delegate: pipe!)
//                    
//                } else {
//                    //                videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
//                    videoCapturer = CustomCameraVideoCapturer(delegate: videoSource)
//                }
//            }
//            
//            if isVideoEnabled() {
//                let captureStarted = startCapture()
//                if !captureStarted {
//                    return nil
//                }
//            }
//        #endif
//            
//            let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
////            videoTrack.isEnabled = isVideoEnabled()
//            return videoTrack
//        }
//    }
    
    
    @discardableResult
    private func addLocalMediaStream() -> Bool {
        
        guard let factory else { return false }
        
        printf("Add local media streams")
        
        // Create Video Track
        localVideoTrack = createVideoTrack()
        videoSender = peerConnection?.add(localVideoTrack,  streamIds: [LOCAL_MEDIA_STREAM_ID])
        
        if let params = videoSender?.parameters {
            params.degradationPreference = (degradationPreference.rawValue) as NSNumber
            videoSender?.parameters = params
        } else {
            printf("DegradationPreference cannot be set")
        }
        
        // Create Audio Track
        let audioSource = factory.audioSource(with: Config.createTestConstraints())
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: AUDIO_TRACK_ID)
        peerConnection?.add(localAudioTrack, streamIds: [LOCAL_MEDIA_STREAM_ID])
        
        if localVideoTrack != nil && localVideoView != nil {
            localVideoTrack.add(localVideoView!)
        }
        
        delegate?.addLocalStream(streamId: streamId)
        
        // ── ADD: spin up the adaptive streamer ──────────────────────
        startAdaptiveStreamer()
        // ────────────────────────────────────────────────────────────
        
        return true
    }
    
    
    /// Creates and starts the adaptive streamer for the current sender.
    /// Idempotent: tearing down the old one before creating a new one.
    private func startAdaptiveStreamer() {

        // Tear down any previous instance (handles re-creation paths like
        // switchToScreencast / useVideoEffect).
        adaptiveStreamer?.stop()
        adaptiveStreamer = nil

        guard let pc = peerConnection,
              let sender = videoSender else {
            printf("startAdaptiveStreamer: no peer connection or video sender; skipping")
            return
        }

        // Infer initial content type. If the caller explicitly sets one later
        // via `setStreamContentType(_:)`, that overrides this guess.
        let contentType: StreamContentType = useExternalCameraSource ? .screenShare : .general

        let streamer = AdaptiveVideoStreamer(
            peerConnection: pc,
            videoSender: sender,
            contentType: contentType
        )

        // Honor any pre-existing bitrate cap the caller already configured.
        streamer.bitrateCeilingBps = maxVideoBpsCeiling?.intValue

        streamer.onProfileChange = { [weak self] profile in
            self?.printf("Adaptive profile → \(profile.name) "
                         + "(\(profile.maxBitrateBps/1000)kbps @ \(profile.maxFramerate)fps, "
                         + "scale \(profile.scaleResolutionDownBy)x)")
        }

        streamer.start()
        adaptiveStreamer = streamer
        printf("Adaptive streamer started (contentType=\(contentType))")
    }
    
    
    public func setDegradationPreference(degradationPreference:RTCDegradationPreference) {
        self.degradationPreference = degradationPreference
    }
    
    public func switchCamera() {
//        if let cameraVideoCapturer = videoCapturer as? RTCCameraVideoCapturer {
        if let cameraVideoCapturer = videoCapturer as? CustomCameraVideoCapturer {
            cameraVideoCapturer.stopCapture()
            
            if cameraPosition == .front {
                cameraPosition = .back
            } else {
                cameraPosition = .front
            }
            
            startCapture()
        }
    }
    
    public func switchToScreencast(_ screenCast: Bool) {
        useExternalCameraSource = screenCast
        externalVideoCapture = screenCast
        
        if videoCapturer is CustomCameraVideoCapturer {
            (videoCapturer as? CustomCameraVideoCapturer)?.stopCapture()
        } else if videoCapturer is RTCCustomFrameCapturer {
            (videoCapturer as? RTCCustomFrameCapturer)?.stopCapture()
        }
        
        if let videoSender {
            videoSender.track = nil
        }
        
        localVideoTrack = createVideoTrack()
        videoSender?.track = localVideoTrack
        
        if let localVideoView {
            localVideoTrack.add(localVideoView)
            //            localVideoTrack.isEnabled = true
        }
        
        adaptiveStreamer?.contentType = screenCast ? .screenShare : .general
        
    }
    
    public func setRTCFile(name: String) {
        rtcFileName = name
    }
    
    public func getLocalTrack() -> RTCVideoTrack {
        localVideoTrack
    }
    
    public func useVideoEffect(_ effect: VideoEffect? = nil) {
        
        self.videoEffect = effect
        
        if videoCapturer is CustomCameraVideoCapturer {
            (videoCapturer as? CustomCameraVideoCapturer)?.stopCapture()
        } else if videoCapturer is RTCCustomFrameCapturer {
            (videoCapturer as? RTCCustomFrameCapturer)?.stopCapture()
        }
        
        if let videoSender {
            videoSender.track = nil
        }
        
        localVideoTrack = createVideoTrack()
        videoSender?.track = localVideoTrack
        
        if let localVideoView {
            localVideoTrack.add(localVideoView)
            //            localVideoTrack.isEnabled = true
        }
        
        adaptiveStreamer?.contentType = .general
        
    }
    
    public func deliverExternalAudio(sampleBuffer: CMSampleBuffer) {
        audioDeviceModule?.deliverRecordedData(sampleBuffer)
    }
    
    public func getVideoCapturer() -> RTCVideoCapturer? {
        videoCapturer
    }
    
}

extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        delegate?.dataReceivedFromDataChannel(didReceiveData: buffer, streamId: streamId)
    }
    
    func dataChannelDidChangeState(_ parametersdataChannel: RTCDataChannel)  {
        delegate?.rtcDataChannelDidChangeState(parametersdataChannel.readyState)
        
        if (parametersdataChannel.readyState == .open) {
            printf("Data channel state is open")
        } else if  (parametersdataChannel.readyState == .connecting) {
            printf("Data channel state is connecting")
        } else if  (parametersdataChannel.readyState == .closing) {
            printf("Data channel state is closing")
        } else if  (parametersdataChannel.readyState == .closed) {
            printf("Data channel state is closed")
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        
    }
    
    
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    
    // signalingStateChanged
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        //printf("---> StateChanged:\(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        printf("didAdd track:\(String(describing: rtpReceiver.track?.kind)) media streams count:\(mediaStreams.count) ")
        
        if let track = rtpReceiver.track {
            delegate?.trackAdded(track:track, stream:mediaStreams)
        } else {
            printf("New track added but it's nil")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        printf("didRemove track:\(String(describing: rtpReceiver.track?.kind))")
        
        if let track = rtpReceiver.track {
            delegate?.trackRemoved(track:track)
        } else {
            printf("New track removed but it's nil")
        }
    }
    
    // addedStream
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        
        printf("addedStream. Stream has \(stream.videoTracks.count) video tracks and \(stream.audioTracks.count) audio tracks");
        
        if stream.videoTracks.count == 1 {
            printf("stream has video track")
            if remoteVideoView != nil {
                remoteVideoTrack = stream.videoTracks[0]
                
                //remoteVideoTrack.setEnabled(true)
                remoteVideoTrack.add(remoteVideoView!)
                printf("Has delegate??? (signalingStateChanged): \(String(describing: self.delegate))")
            }
        }
        
        
        delegate?.remoteStreamAdded(streamId: streamId)
    }
    
    // removedStream
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        printf("RemovedStream")
        delegate?.remoteStreamRemoved(streamId: self.streamId);
        remoteVideoTrack = nil
        remoteAudioTrack = nil
    }
    
    // GotICECandidate
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let streamId,
              let id = candidate.sdpMid else { return }
        
        let candidateJson = ["command": "takeCandidate",
                             "type" : "candidate",
                             "streamId": streamId,
                             "candidate" : candidate.sdp,
                             "label": candidate.sdpMLineIndex,
                             "id": id] as [String : Any]
        
        delegate?.sendMessage(candidateJson)
    }
    
    // iceConnectionChanged
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        printf("---> iceConnectionChanged: \(newState.rawValue) for stream: \(String(describing: self.streamId))")
        self.iceConnectionState = newState
        delegate?.connectionStateChanged(newState: newState, streamId: streamId)
    }
    
    // iceGatheringChanged
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        //printf("---> iceGatheringChanged")
    }
    
    // didOpen dataChannel
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        printf("---> dataChannel opened")
        self.dataChannel = dataChannel
        self.dataChannel?.delegate = self
        
    }
    
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        printf("---> peerConnectionShouldNegotiate")
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        //printf("---> didRemove")
    }
}

extension WebRTCClient {
    func printf(_ msg: String) {
        debugPrint("--> AntMediaSDK: " + msg)
    }
}
