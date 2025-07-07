//
//  WebRTCClient.swift
//  AntMediaSDK
//
//  Copyright © 2018 AntMedia. All rights reserved.
//

import Foundation
import AVFoundation
import Starscream
import WebRTC

let TAG: String = "AntMedia_iOS: "

public enum AntMediaClientMode: Int {
    case join = 1
    case play = 2
    case publish = 3
    //deprecated
    case conference = 4;
    case unspecified = 5;
    
    
    func getLeaveMessage() -> String {
        switch self {
            case .join:
                return "leave"
            case .publish, .play:
                return "stop"
            case .conference:
                return "leaveRoom"
            case .unspecified:
                return "unspecified";
        }
    }
    
    func getName() -> String {
        switch self {
        case .join:
            return "join"
        case .play:
            return "play"
        case .publish:
            return "publish"
        case .conference:
            return "conference"
        case .unspecified:
            return "unspecified"
        }
    }
    
}
open class AntMediaClient: NSObject, AntMediaClientProtocol {
    
 
    internal static var isDebug: Bool = false
    internal static var isVerbose: Bool = false
    public weak var delegate: AntMediaClientDelegate?

    private var wsUrl: String!
    private var publisherStreamId: String? = nil;
    /**
     mainTrackId can also be used  the roomId of the conference
     */
    private var mainTrackId: String?
    private var playerStreamId: String?
    public var p2pStreamId: String?
    private var publishToken: String?
    private var playToken: String?
    private var webSocket: WebSocket?
    //keep it for backward compatibility
    private var mode: AntMediaClientMode!
    var streamsInTheRoom:[String] = [];
    
    var audioLevelGetterTimer: Timer?;
    
    var rtcStatsTimer: Timer?
    var rtcStatsStreamIdSet = Set<String>()

    //private var webRTCClient: WebRTCClient?;
    private var webRTCClientMap: [String: WebRTCClient] = [:]

    private var localView: RTCVideoRenderer?
    private var remoteView: RTCVideoRenderer?
    
    private var videoContentMode: UIView.ContentMode?
    
    private let dispatchQueue = DispatchQueue(label: "audio")
    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    
    private var localContainerBounds: CGRect?
    private var remoteContainerBounds: CGRect?
    
    private var cameraPosition: AVCaptureDevice.Position = .front
    
    private var targetWidth: Int = 1280
    private var targetHeight: Int = 720
    
    private var maxVideoBps: NSNumber = 0;
    
    private var videoEnable: Bool = true
    private var audioEnable: Bool = true
            
    private var enableDataChannel: Bool = true
        
    //Screen capture of the app's screen.
    private var useExternalCameraSource: Bool = false
    
    private var videoEffect: VideoEffect? = nil
    
    private var isWebSocketConnected: Bool = false;
    private var isWebSocketConnecting: Bool = false;
    
    private var externalAudioEnabled: Bool = false;
    
    // External video capture is getting frames from Broadcast Extension.
    //In order to make the broadcast extension to work both captureScreenEnable and
    // externalVideoCapture should be true
    private var externalVideoCapture: Bool = false;
    
    private var cameraSourceFPS: Int = 30;
    
    
    private var userId: Int?
    private var username: String?
    private var profilePicture: String?
    private var role: String?
    
    private var metaData: [String: Any] = [:]
    
    private var rtcFileName: String = ""
    
    /**
    Degradation preference when publishing streams. By default its values is maintainResolution because when resolution changes HLS playback does not play in safari
    */
    private var degradationPreference: RTCDegradationPreference = RTCDegradationPreference.maintainResolution;
    
    var pingTimer: Timer?
    
    var disableTrackId:String?
    
    var reconnectIfRequiresScheduled: Bool = false;
        
    struct HandshakeMessage:Codable {
        var command:String?
        var streamId:String?
        var token:String?
        var video:Bool?
        var audio:Bool?
        var mode:String?
        var mainTrack:String?
        var trackList:[String]
        var metaData: String?
        var streamName: String?
    }
    
    struct VideoMetaData: Codable {
        var isMicMuted: Bool?
        var isCameraOff: Bool?
        var userId: Int?
        var username: String?
        var profilePicture: String?
        var role: String?
    }
    
    public override init() {
    }
    
    public func setMetaData(_ metaData: [String: Any]) {
        self.metaData = metaData
    }
    
    public func setUsernameInfo(userId: Int?, username: String, profilePicture: String, role: String) {
        self.userId = userId
        self.username = username
        self.profilePicture = profilePicture
        self.role = role
    }
    
    public func setOptions(url: String, streamId: String, token: String = "", mode: AntMediaClientMode = .join, enableDataChannel: Bool = false, useExternalCameraSource: Bool = false) {
        self.wsUrl = url
        
        self.mode = mode
        if self.mode == AntMediaClientMode.publish {
            self.publisherStreamId = streamId;
            self.publishToken = token;
        }
        else if (self.mode == AntMediaClientMode.play) {
            self.playerStreamId = streamId;
            self.playToken = token;
        }
        else if self.mode == AntMediaClientMode.join {
            self.p2pStreamId = streamId;
        }
        self.enableDataChannel = enableDataChannel
        self.useExternalCameraSource = useExternalCameraSource
    }
    
    public func setWebSocketServerUrl(url: String) {
        self.wsUrl = url;
    }
    
    public func setRoomId(roomId: String) {
        self.mainTrackId = roomId
    }
    
    public func setEnableDataChannel(enableDataChannel: Bool) {
        self.enableDataChannel = enableDataChannel;
    }
    
    public func setUseExternalCameraSource(useExternalCameraSource: Bool) {
        self.useExternalCameraSource = useExternalCameraSource;
    }
    
    public func setMaxVideoBps(videoBitratePerSecond: NSNumber) {
        self.maxVideoBps = videoBitratePerSecond;
        webRTCClientMap[getPublisherStreamId()]?.setMaxVideoBps(maxVideoBps: videoBitratePerSecond)
    }
    
    public func setVideoEnable( enable: Bool) {
        self.videoEnable = enable
    }
    
    public func getStreamId(_ streamId:String = "") -> String {
        if streamId.isEmpty {
            return publisherStreamId ?? (playerStreamId ?? (p2pStreamId ?? ""))
        } else {
            return streamId
        }
    }
    
    public func getPublisherStreamId() -> String {
        publisherStreamId ?? (p2pStreamId ?? "")
    }
    
    
    public func updateMetaData(isMicMuted: Bool, isCameraOff: Bool) {
        let metaData = VideoMetaData(isMicMuted: isMicMuted,
                                     isCameraOff: isCameraOff,
                                     userId: userId,
                                     username: username,
                                     profilePicture: profilePicture,
                                     role: role)
        
        let metaDataJSON = try! JSONEncoder().encode(metaData)
        
//        guard let metaDataJSON = try? JSONSerialization.data(withJSONObject: metaData, options: .prettyPrinted) else {
//            print("Something is wrong while converting dictionary to JSON data.")
//            return
//        }
        
        let metaDataJSONString = String(data: metaDataJSON, encoding: .utf8)
        
        guard let metaDataJSONString else { return }
        
        let streamId = getStreamId()
        let command = [
            "command": "updateStreamMetaData",
            "streamId": streamId,
            "metaData": metaDataJSONString
        ]
        
        webSocket?.write(string: command.json)
    }
    
    public func requestP2PMetaData() {
        guard let streamId = p2pStreamId else { return }
        sendNotification(eventType: REQUEST_P2P_METADATA, streamId: streamId)
    }
    
    
    func getHandshakeMessage(streamId: String, mode: AntMediaClientMode, token:String = "") -> String {
        
        var trackList: [String] = []
        printf("disable track id is \(String(describing: disableTrackId))")
        
        if let trackId = disableTrackId {
            printf("appending track id to the tracklist \(String(describing: self.disableTrackId))")
            trackList.append("!" + trackId)
        } else {
            printf("Disable track id is not set \(String(describing: self.disableTrackId))")
        }
        
        let metaData = VideoMetaData(isMicMuted: !audioEnable,
                                     isCameraOff: !videoEnable,
                                     userId: userId,
                                     username: username,
                                     profilePicture: profilePicture,
                                     role: role)
        
        let metaDataJSON = try! JSONEncoder().encode(metaData)
        let metaDataJSONString = String(data: metaDataJSON, encoding: .utf8)
        
        let handShakeMesage = HandshakeMessage(command: mode.getName(),
                                               streamId: streamId,
                                               token: token,
                                               video: videoEnable,
                                               audio: audioEnable,
                                               mainTrack: mainTrackId,
                                               trackList: trackList,
                                               metaData: metaDataJSONString!,
                                               streamName: username ?? streamId)
        
        let json = try! JSONEncoder().encode(handShakeMesage)
        return String(data: json, encoding: .utf8)!
    }
    public func getLeaveMessage(streamId: String, mode:AntMediaClientMode) -> [String: String] {
        return [COMMAND: mode.getLeaveMessage(), STREAM_ID: streamId]
    }
    
    // Force speaker
    public static func speakerOn() {
        DispatchQueue.global(qos: .userInitiated).async {
            let rtcAudioSession = RTCAudioSession.sharedInstance()
            rtcAudioSession.lockForConfiguration()
            do {
                try rtcAudioSession.overrideOutputAudioPort(.speaker)
                try rtcAudioSession.setActive(true)
            } catch let error {
                print("Couldn't force audio to speaker: \(error)")
            }
            rtcAudioSession.unlockForConfiguration()
        }
    }
    
    // Fallback to the default playing device: headphones/bluetooth/ear speaker
    public static func speakerOff() {
        DispatchQueue.global(qos: .userInitiated).async {
            let rtcAudioSession = RTCAudioSession.sharedInstance()
            rtcAudioSession.lockForConfiguration()
            do {
                try rtcAudioSession.overrideOutputAudioPort(.none)
            } catch let error {
                debugPrint("Error setting AVAudioSession category: \(error)")
            }
            rtcAudioSession.unlockForConfiguration()
        }
    }

    
    open func start() {
       
        initPeerConnection(streamId: self.getStreamId(), mode: self.mode, token: self.publishToken ?? (self.playToken ?? ""))
        if (!isWebSocketConnected) {
            connectWebSocket()
        }
        else {
            self.websocketConnected();
        }
    }
    
    /**
    Join P2P call
     */
    public func join(streamId:String)
    {
        self.p2pStreamId = streamId;
        resetDefaultWebRTCAudioConfiguation();
        initPeerConnection(streamId: streamId, mode: AntMediaClientMode.join)
        if (!isWebSocketConnected) {
            connectWebSocket();
        }
        else {
            sendJoinCommand(streamId)
        }
    }
    
    /**
     Leave from p2p call
     */
    public func leave(streamId:String) {
        if !isWebSocketConnected {
            let leaveMessage =  [
                COMMAND: "leave",
                STREAM_ID: streamId] as [String : Any]
        
            webSocket?.write(string:leaveMessage.json)
        }
        webRTCClientMap.removeValue(forKey: streamId)?.disconnect();
    }
    
    public func joinRoom(roomId:String, streamId: String = "") {
        self.mainTrackId = roomId;
        self.publisherStreamId = streamId;
        self.mode = AntMediaClientMode.conference;
        if (!isWebSocketConnected) {
            connectWebSocket()
        }
        else {
            sendJoinConferenceCommand()
        }
    }
    
    /**
     Called when the server responds with "joined room notification" as a response to "join room" command
     */
    private func joinedRoom(streamId:String, streams:[String]) {
        
        self.publisherStreamId = streamId;
        self.delegate?.streamIdToPublish(streamId: streamId);
        self.streamsInTheRoom = streams;
        
        if (self.streamsInTheRoom.count > 0) {
            self.delegate?.newStreamsJoined(streams: streams);
        }
        
        reconnectIfRequires()
        
    }
    
    public func leaveFromRoom() {
        if (isWebSocketConnected)
        {
            if let roomId = self.mainTrackId {
                let leaveRoomMessage =  [
                    COMMAND: "leaveFromRoom",
                    ROOM_ID: roomId,
                    STREAM_ID: self.publisherStreamId ?? "" ] as [String : Any]
                
                webSocket?.write(string: leaveRoomMessage.json)
                printf("Sending leaveRoom message \(leaveRoomMessage.json)");
            }
            else {
                printf("Websocket is not connected to send leave from room message");
            }
        }
        if let tmpStreamId = self.publisherStreamId {
            self.webRTCClientMap.removeValue(forKey: tmpStreamId)?.disconnect();
        }
        
        if let tmpStreamId = self.playerStreamId {
            self.webRTCClientMap.removeValue(forKey: tmpStreamId)?.disconnect()
        }
    }
    
    //this configuration don't ask for mic permission it's useful for playback
    public func dontAskMicPermissionForPlaying() {
        let webRTCConfiguration = RTCAudioSessionConfiguration.init()
        webRTCConfiguration.mode = AVAudioSession.Mode.moviePlayback.rawValue
        webRTCConfiguration.category = AVAudioSession.Category.playback.rawValue
        webRTCConfiguration.categoryOptions = AVAudioSession.CategoryOptions.duckOthers
                             
        RTCAudioSessionConfiguration.setWebRTC(webRTCConfiguration)
    }
    
    //this configuration ask mic permission and capture mic record
    public func resetDefaultWebRTCAudioConfiguation() {
        RTCAudioSessionConfiguration.setWebRTC(RTCAudioSessionConfiguration.init())
    }
    
    public func publish(streamId: String, token: String = "", mainTrackId: String = "") {
    
        self.publisherStreamId = streamId;
        //reset default webrtc audio configuation to capture audio and mic
        resetDefaultWebRTCAudioConfiguation();
        initPeerConnection(streamId: streamId, mode: AntMediaClientMode.publish, token: token)
        if (!mainTrackId.isEmpty) {
            self.mainTrackId = mainTrackId
        }
        if (!token.isEmpty) {
            self.publishToken = token;
        }
        if (!isWebSocketConnected) {
            connectWebSocket();
        }
        else {
            sendPublishCommand(streamId)
        }
    }
    
    public func play(streamId: String, token: String = "") {
        
        self.playerStreamId = streamId
        
        if !token.isEmpty {
            self.playToken = token
        }
        
        if let streamId = publisherStreamId {
            if webRTCClientMap[streamId] == nil {
                //if there is not publisherStreamId, don't ask mic permission for playing
                dontAskMicPermissionForPlaying()
            }
        } else {
            //if there is not publisherStreamId, don't ask mic permission for playing
            dontAskMicPermissionForPlaying();
        }
        
        initPeerConnection(streamId: streamId, mode: AntMediaClientMode.play, token: token)
        
        if !isWebSocketConnected {
            connectWebSocket()
        } else {
            sendPlayCommand(streamId)
        }
    }
    
    
    /*
     Connect to websocket.
     */
    open func connectWebSocket() {
        dispatchQueue.async { [weak self] in
            guard let self else { return }
            
            printf("Connect websocket to \(getWsUrl())")
            if (!isWebSocketConnected && !isWebSocketConnecting) { //provides backward compatibility
                isWebSocketConnecting = true
                streamsInTheRoom.removeAll()
                printf("Will connect to: \(getWsUrl()) for stream: \(self.getStreamId())")
                
                webSocket = WebSocket(request: getRequest())
                webSocket?.delegate = self
                webSocket?.connect()
            } else {
                if isWebSocketConnected {
                    printf("WebSocket is already connected to: \(getWsUrl())")
                }
                
                if isWebSocketConnecting {
                    printf("WebSocket is connecting to: \(getWsUrl())")
                }
            }
        }
    }
    
    open func setCameraPosition(position: AVCaptureDevice.Position) {
        self.cameraPosition = position
    }
    
    open func setTargetResolution(width: Int, height: Int) {
        self.targetWidth = width
        self.targetHeight = height
    }
    
    open func setTargetFps(fps: Int) {
        self.cameraSourceFPS = fps;
    }
    
    /*
     Get a default value to make it compatible with old version
     */
    open func stop(streamId:String = "") {
        rtcAudioSession.remove(self);
        let tmpStreamId = getStreamId(streamId)
        
        printf("Stop is called for \(tmpStreamId)")
                            
        if tmpStreamId == self.p2pStreamId
        {
            //provide backward compatibility
            if tmpStreamId == streamId {
                leave(streamId: tmpStreamId)
            }
        }
        else {
            //removing means that user requests to stop
            unregisterStatsListener(streamId: tmpStreamId);
            self.webRTCClientMap.removeValue(forKey: tmpStreamId)?.disconnect();
            
            if (isWebSocketConnected) {
                let command =  [
                    COMMAND: "stop",
                    STREAM_ID: tmpStreamId] as [String : String];
                
                webSocket?.write(string: command.json)
            }
            else {
                printf("Websocket is not connected to stop stream:\(tmpStreamId)")
            }
            
            if (self.publisherStreamId == tmpStreamId) {
                self.publisherStreamId = nil
            }
            else if (self.playerStreamId == tmpStreamId) {
                self.playerStreamId = nil;
            }
            
        }
        
    }
    
    open func removePeerConnection(_ streamId: String) {
        webRTCClientMap.removeValue(forKey: streamId)
    }
    
    open func initPeerConnection(streamId: String = "", mode:AntMediaClientMode=AntMediaClientMode.unspecified, token: String = "") {
        
        let id = getStreamId(streamId);
        
        if (self.webRTCClientMap[id] == nil) {
            printf("Has wsClient? (start) : \(String(describing: self.webRTCClientMap[id]))")
            
            self.webRTCClientMap[id] = WebRTCClient.init(remoteVideoView: remoteView, localVideoView: localView, delegate: self, mode: mode != .unspecified ? mode : self.mode , cameraPosition: self.cameraPosition, targetWidth: self.targetWidth, targetHeight: self.targetHeight, videoEnabled: self.videoEnable, enableDataChannel: self.enableDataChannel, useExternalCameraSource: self.useExternalCameraSource, videoEffect: videoEffect, externalAudio: self.externalAudioEnabled, externalVideoCapture: self.externalVideoCapture, cameraSourceFPS: self.cameraSourceFPS, streamId:id,
                                                         degradationPreference: self.degradationPreference, rtcFileName: self.rtcFileName);
            
            self.webRTCClientMap[id]?.setToken(token)
            
            rtcAudioSession.add(self)
        }
        else {
            //it may initialized without correct token parameter because of backward compatibility
            self.webRTCClientMap[id]?.setToken(token)
            printf("WebRTCClient already initialized for id:\(id) and mode:\(mode.getName())")
        }
    }
    
    /// Video Effect
    
    open func useVideoEffect(_ effect: VideoEffect? = nil) {
        self.videoEffect = effect
        webRTCClientMap[(publisherStreamId ?? p2pStreamId) ?? ""]?.useVideoEffect(effect)
    }
    
    
    /*
     Just switches the camera. It works on the fly as well
     */
    open func switchCamera() {
        self.webRTCClientMap[(self.publisherStreamId ?? (self.p2pStreamId)) ?? ""]?.switchCamera()
    }
    
    open func switchScreenCast(_ screenCast: Bool) {
        setUseExternalCameraSource(useExternalCameraSource: screenCast)
        setExternalVideoCapture(externalVideoCapture: screenCast)
        
        webRTCClientMap[(publisherStreamId ?? p2pStreamId) ?? ""]?.switchToScreencast(screenCast)
        sendScreencastStatusNotification(enabled: screenCast)
    }

    /*
     Send data through WebRTC Data channel.
     */
    open func sendData(data: Data, binary: Bool = false, streamId: String = "") {
        self.webRTCClientMap[getStreamId(streamId)]?.sendData(data: data, binary: binary)
    }
    
    open func isDataChannelActive(streamId: String = "") -> Bool {
       
        return self.webRTCClientMap[getStreamId(streamId)]?.isDataChannelActive() ?? false
    }
        
    open func setLocalView( container: UIView, mode:UIView.ContentMode = .scaleAspectFit) {
       
        #if arch(arm64)
        let localRenderer = RTCMTLVideoView(frame: container.frame)
        localRenderer.videoContentMode =  mode
        #else
        let localRenderer = RTCEAGLVideoView(frame: container.frame)
        localRenderer.delegate = self
        #endif
 
        localRenderer.frame = container.bounds
        self.localView = localRenderer
        self.localContainerBounds = container.bounds
        
        embedView(localRenderer, into: container)
    }
    
    open func setRemoteView(remoteContainer: UIView, mode:UIView.ContentMode = .scaleAspectFit) {
       
        #if arch(arm64)
        let remoteRenderer = RTCMTLVideoView(frame: remoteContainer.frame)
        remoteRenderer.videoContentMode = mode
        #else
        let remoteRenderer = RTCEAGLVideoView(frame: remoteContainer.frame)
        remoteRenderer.delegate = self
        #endif
        
        remoteRenderer.frame = remoteContainer.frame
        
        self.remoteView = remoteRenderer
        self.remoteContainerBounds = remoteContainer.bounds
        embedView(remoteRenderer, into: remoteContainer)
        
    }
    
    open func disableTrack(trackId:String) {
        self.disableTrackId = trackId;
    }
    
    public func embedView(_ view: UIView, into containerView: UIView) {
        containerView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "H:|[view]|",
                                                                    options: [],
                                                                    metrics: nil,
                                                                    views: ["view":view]))
        
        containerView.addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|[view]|",
                                                                    options: [],
                                                                    metrics: nil,
                                                                    views: ["view":view]))
        containerView.layoutIfNeeded()
    }
    
    open func isConnected() -> Bool {
        return isWebSocketConnected;
    }
    
    open func setDebug(_ value: Bool) {
        AntMediaClient.isDebug = value
    }
    
    public static func setDebug(_ value: Bool) {
         AntMediaClient.isDebug = value
    }
    
    /*
     Toggle publisher audo
     */
    open func toggleAudio() {
        self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.toggleAudioEnabled()
        
        if let audioEnabled = self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.isAudioEnabled() {
            self.sendAudioTrackStatusNotification(enabled: audioEnabled)
        }
       
    }
    
    func sendAudioTrackStatusNotification(enabled:Bool)
    {
        var eventType = EVENT_TYPE_MIC_MUTED;
        if (enabled) {
            eventType = EVENT_TYPE_MIC_UNMUTED;
        }
        if let streamId = self.publisherStreamId {
            self.sendNotification(eventType: eventType, streamId:streamId);
        }
    }
    /*
     Set publisher audio track
     */
    open func setAudioTrack(enableTrack: Bool) {
        self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.setAudioEnabled(enabled: enableTrack);
        self.sendAudioTrackStatusNotification(enabled:enableTrack);
    }
    
    
    
    public func sendNotification(eventType:String, streamId: String = "", info: [String: String]? = nil) {
        var notification =  [
            EVENT_TYPE: eventType,
            STREAM_ID: self.getStreamId()]
        
        if let info {
            notification.merge(info) { _, new in new }
        }
        
        if let data = notification.json.data(using: .utf8) {
            self.webRTCClientMap[self.publisherStreamId ?? (self.p2pStreamId ?? "")]?.sendData(data: data);
        }
       
    }
    
    open func setMicMute(mute: Bool, completionHandler: @escaping (Bool, Error?) -> Void) {
        dispatchQueue.async { [weak self] in
            
            guard let self else { return }
           
            rtcAudioSession.lockForConfiguration()
            do {
                var category:String;
                if (mute) {
                    category = AVAudioSession.Category.soloAmbient.rawValue;
                }
                else {
                    category = AVAudioSession.Category.playAndRecord.rawValue;
                }
                try rtcAudioSession.setCategory(category);
                //playAndRecord category defaults receiver to set to speaker
                try rtcAudioSession.overrideOutputAudioPort(.speaker)
                try rtcAudioSession.setActive(true);
                self.webRTCClientMap[self.getPublisherStreamId()]?.setAudioEnabled(enabled: !mute);
                self.sendNotification(eventType: mute ? EVENT_TYPE_MIC_MUTED : EVENT_TYPE_MIC_UNMUTED);
                completionHandler(mute, nil);
                
            } catch let error {
                printf("Couldn't set to mic status: \(error)")
                completionHandler(mute, error);
            }
            rtcAudioSession.unlockForConfiguration()
        }
    }
    
    open func setParticipantMicMute(_ mute: Bool, participantStreamID: String) {
        let eventType = mute ? EVENT_TURN_YOUR_MIC_OFF : EVENT_TURN_YOUR_MIC_ON
        let senderStreamID = getPublisherStreamId()
        
        sendNotification(eventType: eventType,
                         info: ["streamId": participantStreamID,
                                "senderStreamId": senderStreamID])
    }
    
    open func toggleVideo() {
        webRTCClientMap[getPublisherStreamId()]?.toggleVideoEnabled()
        
        if let videoEnabled = webRTCClientMap[getPublisherStreamId()]?.isVideoEnabled() {
            sendVideoTrackStatusNotification(enabled: videoEnabled)
        }
    }
    
    public func setRTCFile(name: String) {
        self.rtcFileName = name
    }
    
    public func getLocalVideoTrack() -> RTCVideoTrack? {
        self.webRTCClientMap[getPublisherStreamId()]?.getLocalTrack()
    }
    
    func sendVideoTrackStatusNotification(enabled:Bool) {
        let eventType = enabled ? EVENT_TYPE_CAM_TURNED_ON : EVENT_TYPE_CAM_TURNED_OFF
        let id = getPublisherStreamId()
        
        sendNotification(eventType: eventType, streamId: id)
    }
    
    func sendScreencastStatusNotification(enabled:Bool) {
        let eventType = enabled ? EVENT_TYPE_SCREENCAST_ON : EVENT_TYPE_SCREENCAST_OFF
        let id = getPublisherStreamId()
        
        sendNotification(eventType: eventType, streamId: id)
    }
    
    open func setVideoTrack(enableTrack: Bool)
    {
        self.webRTCClientMap[getPublisherStreamId()]?.setVideoEnabled(enabled: enableTrack);
        self.sendVideoTrackStatusNotification(enabled:enableTrack);
    }
    
    open func getCurrentMode() -> AntMediaClientMode {
        return self.mode
    }
    
    open func getWsUrl() -> String {
        return wsUrl;
    }
    
    fileprivate func sendPublishCommand(_ streamId: String) {
        if isWebSocketConnected {
            let jsonString = getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.publish, token:self.publishToken ?? "");
            webSocket?.write(string: jsonString)
            printf("Send Publish onConnection message: \(jsonString)")
            //Add 3 seconds delay here and reconnectIfRequires has also 3 seconds delay
            dispatchQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.reconnectIfRequires();
            };
        }
        else {
            printf("Websocket is not connected to send Publish message for stream\(streamId)")
        }
    }
    
    func sendJoinConferenceCommand()
    {
        if isWebSocketConnected
        {
            if let roomId = self.mainTrackId {
                let joinRoomMessage =  [
                    COMMAND: "joinRoom",
                    ROOM_ID: roomId,
                    MODE: "multitrack",
                    STREAM_ID: self.publisherStreamId ?? "" ] as [String : String]
                webSocket?.write(string: joinRoomMessage.json)
            }
            else {
                printf("mainTrackId is not specified to join the room ");
            }
        }
        else {
            printf("Websocket is not connected to send joinConferece message for room \(String(describing: self.mainTrackId))")
        }
    }
    
    fileprivate func sendPlayCommand(_ streamId: String) {
        if (isWebSocketConnected) {
            let jsonString = getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.play, token: self.playToken ?? "");
            webSocket?.write(string: jsonString)
            printf("Play onConnection message: \(jsonString)")
            
            //Add 3 seconds delay here and reconnectIfRequires has also 3 seconds delay
            dispatchQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.reconnectIfRequires();
            };
            
        }
        else {
            printf("Websocket is not connected to send play message for stream: \(streamId)")
        }
    }
    
    fileprivate func sendJoinCommand(_ streamId: String) {
        let jsonString = getHandshakeMessage(streamId: streamId, mode: AntMediaClientMode.join)
        webSocket?.write(string: jsonString)
        printf("P2P onConnection message: \(jsonString)")
    }
    
    private func websocketConnected() {
        
        if (isWebSocketConnected) {
            if mode == AntMediaClientMode.conference {
                sendJoinConferenceCommand();
            }
            //multiple modes can be active at a time so they are "if" statement
            if let streamId = self.publisherStreamId {
                sendPublishCommand(streamId)
            }
            if let streamId = self.playerStreamId {
                sendPlayCommand(streamId)
            }
            if let streamId = self.p2pStreamId {
                sendJoinCommand(streamId)
            }
        }
        
        // setup for audio interruption notification
        self.setupAudioNotifications()
    }
    
    private func websocketDisconnected(message:String, code:UInt16) {
        self.delegate?.clientDidDisconnect(message)
        self.reconnectIfRequires()
    }
    
    /**
     Re-connection Scenario based on Ice Connection State because No matter websocket is disconnected or webrtc is disconnected
     , ice Connection states changes to disconnected and below `reconnectIfRequires` method is called when ice connection is disconnected.
     
     `reconnectIfRequires` checks if connection is in the map because if the connection is stopped by the user, it's removed from the map, then there is nothing to do.
     If it's not removed from the map and its state is closed, disconnected or failed it means that is a reconnect scenario is required.
     
    This method is also called after joining a room to check if it requires to reconnect
     
     */
    private func reconnectIfRequires() {
       
        if reconnectIfRequiresScheduled {
            printf("ReconnectIfRequires is already scheduled and it will work soon")
            return
        }
        
        reconnectIfRequiresScheduled = true
        
        dispatchQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            
            reconnectIfRequiresScheduled = false
            
            if let streamId = self.publisherStreamId {
                //if there is a webRTCClient in the map, it means it's disconnected due to network issue
                if webRTCClientMap[streamId] != nil {
                    let iceState = webRTCClientMap[streamId]?.getIceConnectionState()
                    
                    //check the ice state if this method is triggered consequently
                    if ( iceState == RTCIceConnectionState.closed ||
                         iceState == RTCIceConnectionState.disconnected ||
                         iceState == RTCIceConnectionState.failed ||
                         iceState == RTCIceConnectionState.new
                    ) {
                        //clean the connection
                        webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                        printf("Reconnecting to publish the stream:\(streamId)")
                        publish(streamId:streamId)
                    } else {
                        printf("Not trying to reconnect to publish the stream:\(streamId) because ice connection state is not disconnected")
                    }
                }
            }
            
            if let streamId = self.playerStreamId {
                //if there is a webRTCClient in the map, it means it's disconnected due to network issue
                
                let iceState = self.webRTCClientMap[streamId]?.getIceConnectionState();
                //check the ice state if this method is triggered consequently
                if ( iceState == RTCIceConnectionState.closed ||
                     iceState == RTCIceConnectionState.disconnected ||
                     iceState == RTCIceConnectionState.failed ||
                     iceState == RTCIceConnectionState.new
                )
                {
                    //clean the connection
                    self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                    printf("Reconnecting to play the stream:\(streamId)");
                    self.play(streamId:streamId)
                }
                else {
                    printf("Not trying to reconnect to play the stream:\(streamId) because ice connection state is not disconnected");
                }
            }
            
            if let streamId = self.p2pStreamId {
                //if there is a webRTCClient in the map, it means it's disconnected due to network issue
                if (self.webRTCClientMap[streamId] != nil) {
                    
                    let iceState = self.webRTCClientMap[streamId]?.getIceConnectionState();
                    //check the ice state if this method is triggered consequently
                    if ( iceState == RTCIceConnectionState.closed ||
                         iceState == RTCIceConnectionState.disconnected ||
                         iceState == RTCIceConnectionState.failed
                    )
                    {
                        //clean the connection
                        self.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                        printf("Reconnecting to join the stream:\(streamId) because ice connection state is not disconnected");
                        self.join(streamId:streamId)
                    }
                }
            }
        }
    }
    
    private func onJoined() {
//        delegate?.clientDidJoin()
    }
    
    
    private func onTakeConfiguration(message: [String: Any], streamId:String) {
        guard let type = message["type"] as? String,
              let sdp = message["sdp"] as? String else {
            return
        }
        
        var rtcSessionDesc: RTCSessionDescription
        
        if type == "offer" {
            rtcSessionDesc = RTCSessionDescription.init(type: RTCSdpType.offer, sdp: sdp)
            webRTCClientMap[streamId]?.setRemoteDescription(rtcSessionDesc, completionHandler: { [weak self] error in
                if error == nil {
                    self?.webRTCClientMap[streamId]?.sendAnswer()
                } else {
                    self?.printf("Error (setRemoteDescription): " + error!.localizedDescription + " debug description: " + error.debugDescription)
                }
            })
            
        } else if type == "answer" {
            rtcSessionDesc = RTCSessionDescription(type: RTCSdpType.answer, sdp: sdp)
            webRTCClientMap[streamId]?.setRemoteDescription(rtcSessionDesc, completionHandler: { _ in })
        }
    }
    
    private func onTakeCandidate(message: [String: Any], streamId:String) {
        let mid = message["id"] as! String
        let index = message["label"] as! Int
        let sdp = message["candidate"] as! String
        let candidate: RTCIceCandidate = RTCIceCandidate.init(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: mid)
        
        webRTCClientMap[streamId]?.addCandidate(candidate)
    }
    
    private func onMessage(_ msg: String) {
        guard let message = msg.toJSON(),
              let command = message[COMMAND] as? String else {
            printf("WebSocket message JSON parsing error: " + msg)
            return
        }
        
        onCommand(command, message: message)
    }
    
    private func onCommand(_ command: String, message: [String: Any]) {
        
        switch command {
        case "trackList":
            if let trackList = message["trackList"] as? [String] {
                delegate?.onGetTrackList(trackList)
            }
            
            case "start":
                //if this is called, it's publisher or initiator in p2p
                let streamId = message[STREAM_ID] as! String
                self.webRTCClientMap[streamId]?.createOffer()
            
            case "stop":
                dispatchQueue.async { [weak self] in
                    let streamId = message[STREAM_ID] as! String
                    self?.webRTCClientMap.removeValue(forKey: streamId)?.disconnect()
                }
            
            case "takeConfiguration":
                let streamId = message[STREAM_ID] as! String
                self.onTakeConfiguration(message: message, streamId: streamId)
            
            case "takeCandidate":
                let streamId = message[STREAM_ID] as! String
                self.onTakeCandidate(message: message, streamId: streamId)
                break
            case STREAM_INFORMATION_COMMAND:
                printf("stream information command")
                var streamInformations: [StreamInformation] = [];
                
                if let streamInformationArray = message["streamInfo"] as? [Any]
                {
                    for result in streamInformationArray
                    {
                        if let resultObject = result as? [String:Any]
                        {
                            streamInformations.append(StreamInformation(json: resultObject))
                        }
                    }
                }
                self.delegate?.streamInformation(streamInfo: streamInformations);
                
                break
            case "notification":
                guard let definition = message["definition"] as? String else {
                    return
                }
                
                if definition == "joined" {
                    printf("Joined: Let's go")
                    self.onJoined()
                }
                else if definition == "play_started" {
                    let streamId = message[STREAM_ID] as! String
                    printf("Play started: Let's go")
                    self.delegate?.playStarted(streamId: streamId)
                }
                else if definition == "play_finished" {
                    printf("Playing has finished")
                    self.streamsInTheRoom.removeAll();
                    let streamId = message[STREAM_ID] as! String
                    self.delegate?.playFinished(streamId: streamId)
                    self.unregisterStatsListener(streamId: streamId)
                }
                else if definition == "publish_started" {
                    let streamId = message[STREAM_ID] as! String
                    printf("Publish started: Let's go")
                    self.webRTCClientMap[streamId]?.setMaxVideoBps(maxVideoBps: self.maxVideoBps)
                    self.delegate?.publishStarted(streamId: message[STREAM_ID] as! String)
                }
                else if definition == "publish_finished" {
                    let streamId = message[STREAM_ID] as! String
                    printf("Publish finished: Let's close")
                    self.delegate?.publishFinished(streamId: streamId)
                    self.unregisterStatsListener(streamId: streamId)
                }
                else if definition == JOINED_ROOM_DEFINITION
                {
                    let streamId = message[STREAM_ID] as! String;
                    let streams = message[STREAMS] as! [String];
                    self.joinedRoom(streamId: streamId, streams:streams);
                }
                else if definition == BROADCAST_OBJECT_NOTIFICATION { // broadcastObject
                    if let broadcastString = message["broadcast"] as? String {
                        let broadcastObject = broadcastString.toJSON()
                        delegate?.onLoadBroadcastObject(
                            streamId: message[STREAM_ID] as! String,
                            message: broadcastObject ?? [:]
                        )
                    }
               }
                else if definition == RESOLUTION_CHANGE_INFO_COMMAND {
                    let streamId = message[STREAM_ID] as? String ?? "";
                    self.delegate?.eventHappened(streamId: streamId, eventType: definition, payload: message)
                }
            
                break;
           
            case ROOM_INFORMATION_COMMAND:
                if let updatedStreamsInTheRoom = message[STREAMS] as? [String] {
                   //check that there is a new stream exists
                    var newStreams:[String] = []
                    var leftStreams: [String] = []
                    for stream in updatedStreamsInTheRoom
                    {
                       // AntMedia.printf("stream in updatestreamInTheRoom \(stream)")
                        if (!self.streamsInTheRoom.contains(stream)) {
                            newStreams.append(stream)
                        }
                    }
                    //check that any stream is left
                   for stream in self.streamsInTheRoom {
                       if (!updatedStreamsInTheRoom.contains(stream)) {
                           leftStreams.append(stream)
                       }
                   }
                    
                    self.streamsInTheRoom = updatedStreamsInTheRoom
                    
                    if (newStreams.count > 0) {
                        self.delegate?.newStreamsJoined(streams: newStreams)
                    }
                    
                    if (leftStreams.count > 0) {
                        self.delegate?.streamsLeft(streams: leftStreams)
                    }
                            
                }
                
                break;
            
            case "pong":
                //dont do anything
                break;
            case "error":
                guard let definition = message["definition"] as? String else {
                    self.delegate?.clientHasError("An error occured, please try again")
                    return
                }
                
                self.delegate?.clientHasError(AntMediaError.localized(definition))
                break
            default:
                printf("Unknown message received -> \(message)");
                break
        }
    }
    
    private func getRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: self.getWsUrl())!)
        request.timeoutInterval = 5
        return request
    }
    
    public func printf(_ msg: String) {
        #if DEBUG
        debugPrint("--> AntMediaSDK: " + msg)
        #endif
    }
    
    public static func verbose(_ msg:String) {
//        if (AntMediaClient.isVerbose) {
            debugPrint("--> AntMediaSDK[verbose]: " + msg);
//        }
        
    }
    
    public func getStreamInfo()
    {
        if (self.isWebSocketConnected)
        {
            self.webSocket?.write(string: [COMMAND: GET_STREAM_INFO_COMMAND, STREAM_ID: self.playerStreamId].json)
        }
        else {
            printf("Websocket is not connected")
        }
    }
    
    public func forStreamQuality(resolutionHeight: Int)
    {
        if (self.isWebSocketConnected)
        {
            self.webSocket?.write(string: [COMMAND: FORCE_STREAM_QUALITY_INFO, STREAM_ID: (self.playerStreamId!), STREAM_HEIGHT_FIELD: resolutionHeight].json)
        }
        else {
            printf("Websocket is not connected")
        }
    }
    
    public func forceStreamQuality(resolutionHeight:Int, streamId:String) {
        if (self.isWebSocketConnected)
        {
            self.webSocket?.write(string: [COMMAND: FORCE_STREAM_QUALITY_INFO, STREAM_ID: (self.playerStreamId!), TRACK_ID:streamId, STREAM_HEIGHT_FIELD: resolutionHeight].json)
        }
        else {
            printf("Websocket is not connected")
        }
    }
    
    public func registerStatsListener(for streamId:String, timeInterval:Double = 5) {
        self.rtcStatsTimer?.invalidate();
        
        self.rtcStatsStreamIdSet.insert(streamId)
        self.rtcStatsTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { [weak self] timer in
            
            guard let self = self else { return }

            var itemsToRemove: Set<String> = []

            for streamIdInSet in rtcStatsStreamIdSet
            {
                if let webRTCClient = self.webRTCClientMap[streamIdInSet]
                {
                    webRTCClient.getStats(handler: { [weak self] report in
                        self?.delegate?.onStats(streamId: streamIdInSet, statistics: report)
                    });
                }
                else {
                    itemsToRemove.insert(streamIdInSet);
                }
            }
            
            
            for itemToRemove in itemsToRemove {
                self.unregisterStatsListener(streamId: itemToRemove);
            }
        }
    }
    
    public func unregisterStatsListener(streamId: String) {
        self.rtcStatsStreamIdSet.remove(streamId);
        if (self.rtcStatsStreamIdSet.isEmpty) {
            self.rtcStatsTimer?.invalidate();
            self.rtcStatsTimer = nil
        }
    }
    
    public func getStats(completionHandler: @escaping (RTCStatisticsReport) -> Void, streamId:String = "") {
        
        self.webRTCClientMap[self.getStreamId(streamId)]?.getStats(handler: completionHandler)
    }
    
    public func getStatistics(
        for streamId: String = "",
        completion: @escaping (ClientStatistics) -> Void
    ) {
        getStats(completionHandler: { report in
            completion(.init(items: report.statistics.extractRTCStatItems()))
        }, streamId: streamId)
    }
    
    public func deliverExternalAudio(sampleBuffer: CMSampleBuffer)
    {
        self.webRTCClientMap[getPublisherStreamId()]?.deliverExternalAudio(sampleBuffer: sampleBuffer);
    }
    
    
    public func setExternalAudio(externalAudioEnabled: Bool) {
        self.externalAudioEnabled = externalAudioEnabled;
    }
    
    public func setExternalVideoCapture(externalVideoCapture: Bool) {
        self.externalVideoCapture = externalVideoCapture;
    }
    
    public func deliverExternalVideo(sampleBuffer: CMSampleBuffer, rotation:Int = -1)
    {
        (self.webRTCClientMap[self.getPublisherStreamId()]?.getVideoCapturer() as? RTCCustomFrameCapturer)?.capture(sampleBuffer, externalRotation: rotation);
    }
    
    public func deliverExternalPixelBuffer(pixelBuffer: CVPixelBuffer, rotation:RTCVideoRotation, timestampNs: Int64) {
        (self.webRTCClientMap[self.getPublisherStreamId()]?.getVideoCapturer() as? RTCCustomFrameCapturer)?.capture(pixelBuffer, rotation: rotation, timeStampNs: timestampNs);
    }
    
    /// Pin `streamId` video to `track`
    public func pinVideoTrack(to label: String, streamId: String, isPin: Bool) {
        let command = [
            "command": ASSIGN_VIDEO_TRACK,
            "videoTrackId": label,
            "streamId": streamId,
            "enabled": isPin ? true : false
        ] as [String : Any]
        
        webSocket?.write(string: command.json)
    }
    
    public func writeWebsocketMessage(_ jsonString: String) {
        webSocket?.write(string: jsonString)
    }
    
    /// Get track list in a room
    /// It will return a list of StreamID in `onGetTrackList` delegate
    public func getTrackLists(mainTrackID: String) {
        let command = ["command": "getTrackList",
                      "streamId": mainTrackID,
                      "token": ""]
        
        webSocket?.write(string: command.json)
    }
    
    /// Recall video track assignment
    public func getVideoTrackAssignment(streamId: String) {
        sendCommand(command: GET_VIDEO_TRACK_ASSIGNMENT,
                    streamId: streamId)
    }
    

    public func enableVideoTrack(trackId:String, enabled:Bool){
        if (isWebSocketConnected) {
            
            let jsonString =  [
                COMMAND: ENABLE_VIDEO_TRACK_COMMAND,
                TRACK_ID: trackId,
                STREAM_ID: self.playerStreamId!,
                ENABLED: enabled].json;
            
            webSocket?.write(string: jsonString);
        }
    }
    
    public func enableAudioTrack(trackId:String, enabled:Bool){
        if (isWebSocketConnected) {
            
            let jsonString =  [
                COMMAND: ENABLE_AUDIO_TRACK_COMMAND,
                TRACK_ID: trackId,
                STREAM_ID: self.playerStreamId!,
                ENABLED: enabled].json;
            
            webSocket?.write(string: jsonString);
        }
    }
    
    public func enableTrack(trackId:String, enabled:Bool){
        if (isWebSocketConnected)
        {
            let jsonString =  [
                COMMAND: ENABLE_TRACK_COMMAND,
                TRACK_ID: trackId,
                STREAM_ID: self.playerStreamId!,
                ENABLED: enabled].json;
            
            webSocket?.write(string: jsonString);
        }
        else {
            printf("Websocket is not connected to enableTRack for track: \(trackId) in stream: \(self.playerStreamId)")
        }
    }
    
    public func setDegradationPreference(_ degradationPreference: RTCDegradationPreference)
    {
       self.degradationPreference = degradationPreference;
       let rtc = self.webRTCClientMap[self.getPublisherStreamId()]

       guard let params = rtc?.videoSender?.parameters else {
           return
       }

       params.degradationPreference = (degradationPreference.rawValue) as NSNumber
       rtc?.videoSender?.parameters = params
    }
    
    public func disconnect() {
        for (_, webrtcClient) in self.webRTCClientMap {
            webrtcClient.disconnect()
        }
        
        (localView as? RTCMTLVideoView)?.removeFromSuperview()
        (localView as? RTCMTLVideoView)?.delegate = nil
        
        (localView as? RTCEAGLVideoView)?.removeFromSuperview()
        (localView as? RTCEAGLVideoView)?.delegate = nil
        
        localView = nil
        remoteView = nil
        
        self.webRTCClientMap.removeAll();
        self.webSocket?.disconnect();
        
        // remove audio notifications
        self.removeAudioNotifications()
        
        // remove audio level extractor
        self.removeAudioLevelExtractor()
        
        self.invalidateTimers();
        
        self.webSocket = nil;
        
    }
    
    public func sendCommand(command: String, streamId: String) {
        let command =  [
            COMMAND: command,
            STREAM_ID: streamId
        ].json;

        webSocket?.write(string: command)
    }
    
    public func getBroadcastObject(forStreamId id: String) {
        printf("GetBroadcastObject for \(id)")

        sendCommand(
            command: GET_BROADCAST_OBJECT_COMMAND,
            streamId: id
        )
    }
    
    func invalidateTimers() {
        audioLevelGetterTimer?.invalidate()
        audioLevelGetterTimer = nil
        
        pingTimer?.invalidate()
        pingTimer = nil
        
        rtcStatsTimer?.invalidate()
        rtcStatsTimer = nil
    }
    
    deinit {
        invalidateTimers();
    }
    
}

extension AntMediaClient: WebRTCClientDelegate {
    func onLocalTrackUpdate(track: RTCVideoTrack) {
        delegate?.localStreamUpdate(track: track)
    }
    
    func rtcDataChannelDidChangeState(_ state: RTCDataChannelState) {
        delegate?.dataChannelDidChangeState(state)
    }
        
    func trackAdded(track: RTCMediaStreamTrack, stream: [RTCMediaStream]) {
        self.delegate?.trackAdded(track: track, stream: stream)
    }
    
    func trackRemoved(track: RTCMediaStreamTrack) {
        self.delegate?.trackRemoved(track: track)
    }
    
    
    public func sendMessage(_ message: [String : Any]) {
        self.webSocket?.write(string: message.json)
    }
    
    public func addLocalStream(streamId:String) {
        self.delegate?.localStreamStarted(streamId: streamId)
    }
    
    public func remoteStreamAdded(streamId:String) {
        self.delegate?.remoteStreamStarted(streamId: streamId)
    }
    
    func remoteStreamRemoved(streamId:String) {
        self.delegate?.remoteStreamRemoved(streamId: streamId)
    }
    
    
    public func connectionStateChanged(newState: RTCIceConnectionState, streamId:String) {
        if newState == RTCIceConnectionState.closed ||
            newState == RTCIceConnectionState.disconnected ||
            newState == RTCIceConnectionState.failed
        {
            var state:String = "closed"
            if (newState == RTCIceConnectionState.disconnected) {
                state = "disconnected";
            }
            else {
                state = "failed";
            }
            
            printf("connectionStateChanged: \(state) for stream: \(String(describing:streamId))")
            dispatchQueue.async { [weak self] in
                self?.reconnectIfRequires()
                self?.delegate?.disconnected(streamId: streamId);
            }
        }
    }
    
    public func dataReceivedFromDataChannel(didReceiveData data: RTCDataBuffer, streamId:String) {
        
        let rawJSON = String(decoding: data.data, as: UTF8.self)
        let json = rawJSON.toJSON();
      
        if let eventType = json?[EVENT_TYPE] {
            //event happened
            if let incomingStreamId = json?[STREAM_ID] {
                self.delegate?.eventHappened(streamId:incomingStreamId as! String , eventType:eventType as! String);
                
                self.delegate?.eventHappened(
                                    streamId: incomingStreamId as! String,
                                    eventType: eventType as! String
                                )

                self.delegate?.eventHappened(
                    streamId: incomingStreamId as! String,
                    eventType: eventType as! String,
                    payload: json
                )
                
            }
            else {
                printf("Incoming message does not have streamId:\(json)")
            }
        }
        else {
            self.delegate?.dataReceivedFromDataChannel(streamId: streamId, data: data.data, binary: data.isBinary);
        }
    }
    
}

extension AntMediaClient: WebSocketDelegate {
   
    
    
    
    public func getPingMessage() -> [String: String] {
        return [COMMAND: "ping"]
    }
    
    public func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            isWebSocketConnected = true;
            isWebSocketConnecting = false;
            printf("websocket is connected: \(headers)")
            self.websocketConnected()
            self.delegate?.clientDidConnect(self)
            
            //too keep the connetion alive send ping command for every 10 seconds
            pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] pingTimer in
                guard let self = self else { return }
                let jsonString = self.getPingMessage().json
                self.webSocket?.write(string: jsonString)
            }
            break;
        case .disconnected(let reason, let code):
            isWebSocketConnected = false;
            isWebSocketConnecting = false;
            printf("websocket is disconnected: \(reason) with code: \(code)")
            pingTimer?.invalidate()
            self.websocketDisconnected(message:reason, code:code)
          
            break;
        case .text(let string):
            //printf("Received text: \(string)");
            self.onMessage(string)
            break;
        case .binary(let data):
            printf("Received data: \(data.count)")
            break;
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            isWebSocketConnected = false;
            isWebSocketConnecting = false;
            pingTimer?.invalidate()
            webSocket?.disconnect();
           
            printf("Websocket is cancelled");
            break;
        case .error(let error):
            isWebSocketConnected = false;
            isWebSocketConnecting = false;
            pingTimer?.invalidate()
            webSocket?.disconnect();
            self.websocketDisconnected(message: String(describing: error), code:0);
            printf("Error occured on websocket connection \(String(describing: error))");
            break;
        default:
            printf("Unexpected command received from websocket");
            break;
        }
    }
}

extension AntMediaClient: RTCAudioSessionDelegate
{
    
    public func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        self.delegate?.audioSessionDidStartPlayOrRecord(streamId: self.getStreamId())
    }

}

/*
 This delegate used non arm64 versions. In other words it's used for RTCEAGLVideoView
 */
extension AntMediaClient: RTCVideoViewDelegate {
    
    private func resizeVideoFrame(bounds: CGRect, size: CGSize, videoView: UIView) {
    
        let defaultAspectRatio: CGSize = CGSize(width: size.width, height: size.height)
    
        let videoFrame: CGRect = AVMakeRect(aspectRatio: defaultAspectRatio, insideRect: bounds)
    
        videoView.bounds = videoFrame
    
    }
    
    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        
        printf("Video size changed to " + String(Int(size.width)) + "x" + String(Int(size.height)))
        
        var bounds: CGRect?
        if videoView.isEqual(localView)
        {
            bounds = self.localContainerBounds ?? nil
        }
        else if videoView.isEqual(remoteView)
        {
            bounds = self.remoteContainerBounds ?? nil
        }
       
        if (bounds != nil)
        {
            resizeVideoFrame(bounds: bounds!, size: size, videoView: (videoView as? UIView)!)
        }
    }
}

// MARK: Audio interruption handling section

extension AntMediaClient {
    /// - Regsiters for interruption notifications
    func setupAudioNotifications() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            self?.handleInterruption(notification: notification)
        }
    }
    
    /// - Unregisters for interruption notifications
    func removeAudioNotifications() {
        // Get the default notification center instance.
//        let nc = NotificationCenter.default
//        nc.removeObserver(self,
//                          name: AVAudioSession.interruptionNotification,
//                          object: AVAudioSession.sharedInstance())
    }
    
    /// - Handles audio interruptions
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        
        // Switch over the interruption type.
        switch type {
        case .began:
            // An interruption began. Update the UI as necessary.
            printf("Audio: interruption began")
            break
        case .ended:
            // An interruption ended. Resume playback, if appropriate.
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                // An interruption ended. Resume playback.
                printf("Audio: interruption ended and should resume playback")
                activateAudioSession()
            } else {
                // An interruption ended. Don't resume playback.
                printf("Audio: interruption ended and should not resume playback")
            }
        default:
            break
        }
    }
    
    /// - Activates the audio session
    private func activateAudioSession() {
        dispatchQueue.async { [weak self] in
            guard let self else { return }
            rtcAudioSession.lockForConfiguration()
            rtcAudioSession.isAudioEnabled = true
            rtcAudioSession.unlockForConfiguration()
            printf("Audio: Activated")
        }
    }
}

// MARK: Audio level extrackting section
extension AntMediaClient {
    /// - Registers audio level extractor. Just starts a timer to get statistics
    public func registerAudioLevelExtractor(timeInterval:Double=0.5) {
        audioLevelGetterTimer?.invalidate()

        audioLevelGetterTimer = Timer.scheduledTimer(timeInterval: timeInterval, target: self, selector: #selector(onAudioLevelTimerTicking), userInfo: nil, repeats: true)
    }
    
    /// - Removes audio level extractor
    public func removeAudioLevelExtractor() {
        audioLevelGetterTimer?.invalidate()
        audioLevelGetterTimer = nil
    }
    
    @objc private func onAudioLevelTimerTicking() {
        getStatistics { [weak self] statistics in
            guard let self else {
                return
            }
            let isAudioEnabled = self.webRTCClientMap[
                self.publisherStreamId ?? (self.p2pStreamId ?? "")
            ]?.isAudioEnabled() ?? false
            
            self.delegate?.audioLevelChanged(
                self,
                audioLevel: statistics.audioLevel,
                hasAudio: isAudioEnabled
            )
        }
    }
    
 
}
