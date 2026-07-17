///*
// * Copyright 2017 The WebRTC project authors. All Rights Reserved.
// *
// * Use of this source code is governed by a BSD-style license
// * that can be found in the LICENSE file in the root of the source
// * tree. An additional intellectual property rights grant can be found
// * in the file PATENTS.  All contributing project authors may
// * be found in the AUTHORS file in the root of the source tree.
// */
//
//import AVFoundation
//import CoreMedia
//import UIKit
//import WebRTC
//
//// MARK: - Constants
//
//private enum Constants {
//    static let nanosecondsPerSecond: Int64 = 1_000_000_000
//    static let logTag = "CameraCapturer"
//    static let supportedPixelFormats: Set<FourCharCode> = [
//        kCVPixelFormatType_420YpCbCr8PlanarFullRange,
//        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
//    ]
//}
//
///// Rotation strategy for the capturer.
/////
///// * `.followInterface` — use the app's interface orientation only. Correct
/////   when the app's UI is orientation-locked (e.g. iPhone locked to portrait):
/////   the sent video matches what the user sees on screen, regardless of how
/////   they physically hold the device.
///// * `.followDevice` — use the physical device orientation, falling back to
/////   interface orientation. Correct when the UI rotates with the device
/////   (e.g. iPad supporting all orientations).
///// * `.auto` — `.followInterface` on iPhone, `.followDevice` on iPad. Matches
/////   the common "iPhone portrait-locked, iPad all-orientations" app setup.
//enum CameraRotationStrategy {
//    case followInterface
//    case followDevice
//    case auto
//}
//
//// MARK: - Logging
//
///// Lightweight tagged logger. All logs go through here so they can be filtered
///// in the Xcode console with "[CameraCapturer]" and silenced in one place.
//@inline(__always)
//private func log(_ message: @autoclosure () -> String,
//                 function: String = #function) {
//    print("[\(Constants.logTag)] \(function) — \(message())")
//}
//
//@inline(__always)
//private func logVerbose(_ message: @autoclosure () -> String,
//                        function: String = #function) {
//    #if DEBUG
//    print("[\(Constants.logTag)] \(function) — \(message())")
//    #endif
//}
//
//// MARK: - Helper Extensions
//
//private extension AVCaptureSession.InterruptionReason {
//    var description: String {
//        switch self {
//        case .videoDeviceNotAvailableInBackground:
//            return "Video device is not available in the background."
//        case .audioDeviceInUseByAnotherClient:
//            return "Audio device is in use by another client."
//        case .videoDeviceInUseByAnotherClient:
//            return "Video device is in use by another client."
//        case .videoDeviceNotAvailableWithMultipleForegroundApps:
//            return "Video device is not available with multiple foreground apps."
//        default:
//            return "Unknown interruption reason."
//        }
//    }
//}
//
//private extension UIDeviceOrientation {
//    var debugName: String {
//        switch self {
//        case .unknown: return "unknown"
//        case .portrait: return "portrait"
//        case .portraitUpsideDown: return "portraitUpsideDown"
//        case .landscapeLeft: return "landscapeLeft"
//        case .landscapeRight: return "landscapeRight"
//        case .faceUp: return "faceUp"
//        case .faceDown: return "faceDown"
//        @unknown default: return "unknown(\(rawValue))"
//        }
//    }
//}
//
//private extension UIInterfaceOrientation {
//    var debugName: String {
//        switch self {
//        case .unknown: return "unknown"
//        case .portrait: return "portrait"
//        case .portraitUpsideDown: return "portraitUpsideDown"
//        case .landscapeLeft: return "landscapeLeft"
//        case .landscapeRight: return "landscapeRight"
//        @unknown default: return "unknown(\(rawValue))"
//        }
//    }
//}
//
//private extension RTCVideoRotation {
//    var debugName: String {
//        switch self {
//        case ._0: return "0°"
//        case ._90: return "90°"
//        case ._180: return "180°"
//        case ._270: return "270°"
//        @unknown default: return "unknown(\(rawValue))"
//        }
//    }
//}
//
//private extension AVCaptureDevice {
//    /// Device types available for video capture, organized by iOS version
//    static var availableDeviceTypes: [AVCaptureDevice.DeviceType] {
//        var deviceTypes: [AVCaptureDevice.DeviceType] = [
//            .builtInWideAngleCamera,
//            .builtInTelephotoCamera
//        ]
//
//        if #available(iOS 11.1, *) {
//            deviceTypes.append(.builtInTrueDepthCamera)
//        }
//
//        if #available(iOS 13.0, *) {
//            deviceTypes.append(contentsOf: [
//                .builtInUltraWideCamera,
//                .builtInDualWideCamera,
//                .builtInTripleCamera
//            ])
//        }
//
//        if #available(iOS 10.2, *) {
//            deviceTypes.append(.builtInDualCamera)
//        }
//
//        return deviceTypes
//    }
//}
//
//// MARK: - Main Class
//
//final class CustomCameraVideoCapturer: RTCVideoCapturer {
//
//    // MARK: - State Management
//
//    private enum CaptureState {
//        case idle
//        case starting
//        case running
//        case stopping
//        case error(Error)
//
//        var debugName: String {
//            switch self {
//            case .idle: return "idle"
//            case .starting: return "starting"
//            case .running: return "running"
//            case .stopping: return "stopping"
//            case .error(let e): return "error(\(e.localizedDescription))"
//            }
//        }
//    }
//
//    // MARK: - Public Configuration
//
//    /// How to choose rotation for captured frames. Defaults to `.auto` which
//    /// means "interface orientation on iPhone, device orientation on iPad" —
//    /// matching an app that locks iPhone to portrait and supports all
//    /// orientations on iPad. See `CameraRotationStrategy` for details.
//    var rotationStrategy: CameraRotationStrategy = .auto {
//        didSet { log("rotationStrategy set to \(rotationStrategy)") }
//    }
//
//    /// When `true`, the front camera output is horizontally mirrored — the
//    /// user (and any peer rendering these frames) sees the image the same way
//    /// the iOS Camera app shows its selfie preview: raising your right hand
//    /// shows on the right of the frame, as in a mirror.
//    ///
//    /// Standard WebRTC convention is to leave this `false` (send unmirrored
//    /// frames to the remote peer, and apply a horizontal flip only on the
//    /// local preview view). Flip this back to `false` if the remote peer is
//    /// seeing you mirrored (text backwards) and that's not what you want.
//    var mirrorsFrontCamera: Bool = true {
//        didSet {
//            log("mirrorsFrontCamera set to \(mirrorsFrontCamera)")
//            captureSessionQueue.async { [weak self] in
//                self?.applyVideoMirroring()
//            }
//        }
//    }
//
//    // MARK: - Properties
//
//    private let captureSession: AVCaptureSession
//    private let videoDataOutput: AVCaptureVideoDataOutput
//    private let captureSessionQueue: DispatchQueue
//    private let frameProcessingQueue: DispatchQueue
//
//    private var currentDevice: AVCaptureDevice?
//    private var currentDeviceInput: AVCaptureDeviceInput?
//    private var captureState: CaptureState = .idle
//    private var hasRetriedOnFatalError = false
//
//    // Track last-logged rotation so we only log when it actually changes,
//    // not 30 times a second.
//    private var lastLoggedRotation: RTCVideoRotation?
//
//    // Thread-safe orientation tracking.
//    // We keep BOTH device and interface orientation cached:
//    //  - device orientation = what the camera sensor physically sees (preferred).
//    //  - interface orientation = fallback when device orientation is face-up/face-down/unknown,
//    //    and is also the correct signal on iPad Split View/Slide Over when the device
//    //    hasn't physically moved since launch.
//    private let orientationQueue = DispatchQueue(label: "org.webrtc.cameravideocapturer.orientation", qos: .utility)
//
//    private var _currentInterfaceOrientation: UIInterfaceOrientation = .unknown
//    private var currentInterfaceOrientation: UIInterfaceOrientation {
//        get { orientationQueue.sync { _currentInterfaceOrientation } }
//        set {
//            orientationQueue.async { [weak self] in
//                self?._currentInterfaceOrientation = newValue
//            }
//        }
//    }
//
//    private var _currentDeviceOrientation: UIDeviceOrientation = .unknown
//    private var currentDeviceOrientation: UIDeviceOrientation {
//        get { orientationQueue.sync { _currentDeviceOrientation } }
//        set {
//            orientationQueue.async { [weak self] in
//                self?._currentDeviceOrientation = newValue
//            }
//        }
//    }
//
//    // MARK: - Initialization
//
//    override init(delegate: RTCVideoCapturerDelegate) {
//        
//        self.captureSession = AVCaptureSession()
//        
//        self.videoDataOutput = AVCaptureVideoDataOutput()
//        
//        self.captureSessionQueue = DispatchQueue(
//            label: "org.webrtc.cameravideocapturer.capturesession",
//            qos: .userInitiated,
//            attributes: [],
//            autoreleaseFrequency: .workItem
//        )
//        
//        self.frameProcessingQueue = DispatchQueue(
//            label: "org.webrtc.cameravideocapturer.frameprocessing",
//            qos: .userInitiated,
//            attributes: [],
//            autoreleaseFrequency: .workItem
//        )
//        
//        super.init(delegate: delegate)
//        
//        log("init — idiom=\(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")")
//        // Initialize orientation. We only turn on device-orientation
//        // notifications if our resolved strategy will actually read them,
//        // i.e. on iPad (with .auto) or any device under .followDevice.
//        // This avoids waking the accelerometer on portrait-locked iPhones
//        // where device orientation is ignored anyway.
//        
//        DispatchQueue.main.async { [weak self] in
//            guard let self = self else { return }
//
//            let iface = self.interfaceOrientation
//            self.currentInterfaceOrientation = iface
//
//            if self.shouldTrackDeviceOrientation {
//                
//                if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
//                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
//                    log("Began generating device orientation notifications")
//                }
//                
//                let device = UIDevice.current.orientation
//                if device.isValidInterfaceOrientation {
//                    self.currentDeviceOrientation = device
//                }
//                
//                log("Initial orientation — device=\(device.debugName), interface=\(iface.debugName)")
//                
//            } else {
//                
//                log("Initial orientation — interface=\(iface.debugName) (device orientation not tracked on this idiom)")
//                
//            }
//        }
//
//        setupCaptureSession()
//        
//        addNotificationObservers()
//        
//    }
//
//    deinit {
//        
//        log("deinit")
//        NotificationCenter.default.removeObserver(self)
//
//        // Pair beginGeneratingDeviceOrientationNotifications only if we
//        // actually started it. If another component in the app also depends
//        // on these notifications, consider centralizing this with a refcount.
//        if shouldTrackDeviceOrientation {
//            DispatchQueue.main.async {
//                UIDevice.current.endGeneratingDeviceOrientationNotifications()
//            }
//        }
//
//        // Ensure cleanup happens synchronously without weak reference
//        cleanupCaptureSession()
//        
//    }
//
//    // MARK: - Public API
//
//    func startCapture(
//        with device: AVCaptureDevice,
//        format: AVCaptureDevice.Format,
//        fps: Int
//    ) {
//        
//        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
//        log("startCapture requested — device=\(device.localizedName), position=\(device.position.rawValue), \(dims.width)x\(dims.height) @ \(fps)fps")
//
//        captureSessionQueue.async { [weak self] in
//            self?.performStartCapture(device: device, format: format, fps: fps)
//        }
//        
//    }
//
//    func stopCapture() {
//        
//        log("stopCapture requested")
//        captureSessionQueue.async { [weak self] in
//            self?.performStopCapture()
//        }
//        
//    }
//
//    // MARK: Current Camera
//
//    func isFrontCamera() -> Bool {
//        
//        return captureSession.inputs
//            .compactMap { $0 as? AVCaptureDeviceInput }
//            .contains { $0.device.position == .front }
//        
//    }
//
//    // MARK: - Class Methods
//
//    static func captureDevices() -> [AVCaptureDevice] {
//        
//        if #available(iOS 10.0, *) {
//            let discoverySession = AVCaptureDevice.DiscoverySession(
//                deviceTypes: AVCaptureDevice.availableDeviceTypes,
//                mediaType: .video,
//                position: .unspecified
//            )
//            return discoverySession.devices
//        } else {
//            // Fallback for iOS 9 and earlier
//            return AVCaptureDevice.devices(for: .video)
//        }
//        
//    }
//
//    static func supportedFormats(for device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
//        
//        return device.formats.filter { format in
//            let mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
//            return Constants.supportedPixelFormats.contains(mediaSubType)
//        }
//        
//    }
//
//    // MARK: - Private Implementation
//
//    private func setupCaptureSession() {
//        
//        captureSession.sessionPreset = .inputPriority
//        captureSession.usesApplicationAudioSession = false
//
//        configureVideoDataOutput()
//
//        guard captureSession.canAddOutput(videoDataOutput) else {
//            assertionFailure("Cannot add video data output to capture session")
//            log("ERROR: Cannot add video data output to capture session")
//            return
//        }
//
//        captureSession.addOutput(videoDataOutput)
//        log("Capture session configured — preset=inputPriority, output=videoDataOutput")
//        
//    }
//
//    private func configureVideoDataOutput() {
//        
//        videoDataOutput.videoSettings = [
//            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
//        ]
//        videoDataOutput.alwaysDiscardsLateVideoFrames = true // Optimize for real-time performance
//        videoDataOutput.setSampleBufferDelegate(self, queue: frameProcessingQueue)
//        
//    }
//
//    private func performStartCapture(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
//        
//        guard case .idle = captureState else {
//            log("Cannot start capture: current state is \(captureState.debugName)")
//            return
//        }
//
//        captureState = .starting
//        log("State → starting")
//
//        do {
//            try device.lockForConfiguration()
//            defer { device.unlockForConfiguration() }
//
//            try configureDevice(device, format: format, fps: fps)
//            try configureCaptureSessionInput(for: device)
//
//            // Mirroring can only be set after the connection exists (i.e. after
//            // the input is added above).
//            applyVideoMirroring()
//
//            captureSession.startRunning()
//            captureState = .running
//            currentDevice = device
//            lastLoggedRotation = nil
//            log("State → running — camera is \(device.position == .front ? "FRONT" : "BACK")")
//
//        } catch {
//            captureState = .error(error)
//            log("ERROR: Failed to start capture — \(error.localizedDescription)")
//        }
//        
//    }
//
//    private func performStopCapture() {
//        
//        guard case .running = captureState else {
//            log("Cannot stop capture: current state is \(captureState.debugName)")
//            return
//        }
//
//        captureState = .stopping
//        log("State → stopping")
//
//        // Stop the session
//        if captureSession.isRunning {
//            captureSession.stopRunning()
//        }
//
//        captureSession.beginConfiguration()
//
//        // Clear delegate to prevent callbacks
//        videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
//
//        // Remove inputs only (keep output for potential restart)
//        captureSession.inputs.forEach { captureSession.removeInput($0) }
//
//        captureSession.commitConfiguration()
//
//        // Reset state
//        currentDevice = nil
//        currentDeviceInput = nil
//        lastLoggedRotation = nil
//
//        // Re-configure video output for future use
//        configureVideoDataOutput()
//
//        captureState = .idle
//        log("State → idle")
//        
//    }
//
//    private func configureDevice(_ device: AVCaptureDevice,
//                                 format: AVCaptureDevice.Format,
//                                 fps: Int) throws {
//        
//        device.activeFormat = format
//        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
//        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
//
//        // Optimize for low-light performance if available
//        if device.isLowLightBoostSupported {
//            device.automaticallyEnablesLowLightBoostWhenAvailable = true
//        }
//
//        // Configure focus and exposure for better video quality
//        if device.isFocusModeSupported(.continuousAutoFocus) {
//            device.focusMode = .continuousAutoFocus
//        }
//
//        if device.isExposureModeSupported(.continuousAutoExposure) {
//            device.exposureMode = .continuousAutoExposure
//        }
//
//        log("Device configured — lowLightBoost=\(device.isLowLightBoostSupported), focus=\(device.focusMode.rawValue), exposure=\(device.exposureMode.rawValue)")
//    }
//
//    private func configureCaptureSessionInput(for device: AVCaptureDevice) throws {
//        
//        captureSession.beginConfiguration()
//        defer { captureSession.commitConfiguration() }
//
//        // Remove existing input
//        if let currentInput = currentDeviceInput {
//            captureSession.removeInput(currentInput)
//            log("Removed existing input for \(currentInput.device.localizedName)")
//        }
//
//        // Add new input
//        let deviceInput = try AVCaptureDeviceInput(device: device)
//        guard captureSession.canAddInput(deviceInput) else {
//            log("ERROR: Cannot add input for \(device.localizedName)")
//            throw CaptureError.cannotAddInput
//        }
//
//        captureSession.addInput(deviceInput)
//        currentDeviceInput = deviceInput
//        log("Added input for \(device.localizedName)")
//        
//    }
//
//    /// Applies mirroring policy to the active video connection.
//    ///
//    /// Front camera: mirror if `mirrorsFrontCamera` is true — matches the iOS
//    /// Camera app selfie preview behavior. The user sees a natural "mirror"
//    /// image (raising your right hand shows the hand on the right of the frame).
//    ///
//    /// Back camera: never mirror.
//    private func applyVideoMirroring() {
//        
//        guard let connection = videoDataOutput.connection(with: .video) else {
//            log("applyVideoMirroring: no video connection yet (will apply after input is added)")
//            return
//        }
//
//        let isFront = currentDeviceInput?.device.position == .front
//        let shouldMirror = isFront && mirrorsFrontCamera
//
//        // Must turn off automatic adjustment before manual override.
//        if connection.isVideoMirroringSupported {
//            
//            connection.automaticallyAdjustsVideoMirroring = false
//            connection.isVideoMirrored = shouldMirror
//            log("Mirroring applied — front=\(isFront), mirror=\(shouldMirror)")
//            
//        } else {
//            
//            log("Mirroring not supported on this connection")
//            
//        }
//        
//    }
//
//    private func cleanupCaptureSession() {
//        
//        if captureSession.isRunning {
//            captureSession.stopRunning()
//        }
//
//        captureSession.beginConfiguration()
//
//        // Clear delegate to prevent callbacks during cleanup
//        videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
//
//        // Remove inputs and outputs
//        captureSession.inputs.forEach { captureSession.removeInput($0) }
//        captureSession.outputs.forEach { captureSession.removeOutput($0) }
//
//        captureSession.commitConfiguration()
//
//        // Reset state
//        currentDevice = nil
//        currentDeviceInput = nil
//        
//    }
//
//    // MARK: - Orientation Resolution
//
//    /// Finds the "most correct" interface orientation for the app.
//    ///
//    /// On iPad multi-tasking (Split View / Slide Over), multiple scenes can be
//    /// connected simultaneously and our scene may be `foregroundInactive` while
//    /// still visible. We prefer the scene hosting the key window, then any
//    /// foreground-active scene, then any foreground-inactive scene, then any
//    /// connected scene.
//    private var interfaceOrientation: UIInterfaceOrientation {
//        
//        if #available(iOS 13.0, *) {
//            
//            let scenes = UIApplication.shared.connectedScenes
//                .compactMap { $0 as? UIWindowScene }
//
//            if let keyScene = scenes.first(where: { scene in
//                scene.windows.contains(where: { $0.isKeyWindow })
//            }) {
//                return keyScene.interfaceOrientation
//            }
//            if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
//                return active.interfaceOrientation
//            }
//            if let inactive = scenes.first(where: { $0.activationState == .foregroundInactive }) {
//                return inactive.interfaceOrientation
//            }
//            return scenes.first?.interfaceOrientation ?? .unknown
//            
//        } else {
//            return UIApplication.shared.statusBarOrientation
//        }
//        
//    }
//
//    /// The strategy actually in effect (resolves `.auto` to concrete value).
//    private var effectiveStrategy: CameraRotationStrategy {
//        
//        switch rotationStrategy {
//        case .followInterface, .followDevice:
//            return rotationStrategy
//        case .auto:
//            return UIDevice.current.userInterfaceIdiom == .pad ? .followDevice : .followInterface
//        }
//        
//    }
//
//    /// Whether we need `UIDevice.current.orientation` to be meaningful.
//    /// Only true when the effective strategy reads it.
//    private var shouldTrackDeviceOrientation: Bool {
//        
//        return effectiveStrategy == .followDevice
//        
//    }
//
//    /// Resolves the RTC rotation for the current frame.
//    ///
//    /// Behavior depends on `rotationStrategy`:
//    ///
//    /// * `.followInterface` (typical iPhone with portrait-locked UI):
//    ///   uses the app's interface orientation. On a portrait-locked iPhone
//    ///   this is always `.portrait`, so rotation is constant regardless of
//    ///   how the user physically holds the phone — which is what we want,
//    ///   because the peer should see whatever the user sees.
//    ///
//    /// * `.followDevice` (typical iPad supporting all orientations):
//    ///   uses the physical device orientation (what the sensor actually sees),
//    ///   falling back to interface orientation when device orientation is
//    ///   face-up / face-down / unknown (launch, flat on a table).
//    ///
//    /// Rotation also depends on BOTH camera position and whether the capture
//    /// connection is mirroring:
//    ///
//    /// * Back camera (no mirror): standard rotations.
//    /// * Front camera, NOT mirrored at capture: landscape rotations are
//    ///   inverted by 180° because the front sensor is mounted rotated 180°
//    ///   relative to the back sensor. Portrait rotations match back camera.
//    /// * Front camera, MIRRORED at capture (`isVideoMirrored = true`):
//    ///   `isVideoMirrored` flips the buffer along the sensor's landscape-
//    ///   native horizontal axis. Combined with a 90°/270° display rotation,
//    ///   that horizontal axis becomes the display's vertical axis — so the
//    ///   mirror becomes an upside-down flip. We compensate with a different
//    ///   rotation in every orientation.
//    ///
//    /// Note the inversion between the two enums:
//    ///   UIInterfaceOrientation.landscapeLeft  ≡ UIDeviceOrientation.landscapeRight
//    ///   UIInterfaceOrientation.landscapeRight ≡ UIDeviceOrientation.landscapeLeft
//    private func currentVideoRotation(isUsingFrontCamera: Bool) -> RTCVideoRotation {
//        let mirrored = isUsingFrontCamera && mirrorsFrontCamera
//
//        switch effectiveStrategy {
//        case .followInterface:
//            return rotationFromInterfaceOrientation(
//                currentInterfaceOrientation,
//                isUsingFrontCamera: isUsingFrontCamera,
//                mirrored: mirrored
//            )
//
//        case .followDevice:
//            let deviceOrientation = currentDeviceOrientation
//            if deviceOrientation.isValidInterfaceOrientation {
//                return rotationFromDeviceOrientation(
//                    deviceOrientation,
//                    isUsingFrontCamera: isUsingFrontCamera,
//                    mirrored: mirrored
//                )
//            }
//            // Fallback: device orientation wasn't valid (face-up / face-down
//            // / unknown). Use interface orientation instead.
//            return rotationFromInterfaceOrientation(
//                currentInterfaceOrientation,
//                isUsingFrontCamera: isUsingFrontCamera,
//                mirrored: mirrored
//            )
//
//        case .auto:
//            // effectiveStrategy already resolved .auto; this can't happen.
//            return mirrored ? ._270 : ._90
//        }
//    }
//
//    private func rotationFromDeviceOrientation(
//        _ orientation: UIDeviceOrientation,
//        isUsingFrontCamera: Bool,
//        mirrored: Bool
//    ) -> RTCVideoRotation {
//        switch orientation {
//        case .portrait:
//            // Portrait rotations (90°/270°) swing the sensor's native
//            // horizontal axis onto the display's vertical axis, so a
//            // horizontal mirror appears as an upside-down flip. Compensate
//            // by swapping 90° ↔ 270°.
//            return mirrored ? ._270 : ._90
//
//        case .portraitUpsideDown:
//            return mirrored ? ._90 : ._270
//
//        case .landscapeLeft:
//            // Landscape rotations (0°/180°) keep horizontal axes aligned, so
//            // the mirror produces the intended left-right flip. Front mirrored
//            // should use the SAME rotation as front unmirrored in landscape —
//            // the mirror flip itself is exactly what the selfie view needs.
//            // Device rotated left → home indicator / Dynamic Island on the RIGHT.
//            if isUsingFrontCamera {
//                return ._180
//            }
//            return ._0
//
//        case .landscapeRight:
//            // Device rotated right → home indicator / Dynamic Island on the LEFT.
//            if isUsingFrontCamera {
//                return ._0
//            }
//            return ._180
//
//        default:
//            return mirrored ? ._270 : ._90
//        }
//    }
//
//    private func rotationFromInterfaceOrientation(
//        _ orientation: UIInterfaceOrientation,
//        isUsingFrontCamera: Bool,
//        mirrored: Bool
//    ) -> RTCVideoRotation {
//        switch orientation {
//        case .portrait:
//            return mirrored ? ._270 : ._90
//
//        case .portraitUpsideDown:
//            return mirrored ? ._90 : ._270
//
//        case .landscapeLeft:
//            // UIInterfaceOrientation.landscapeLeft ≡ UIDeviceOrientation.landscapeRight
//            if isUsingFrontCamera {
//                return ._0
//            }
//            return ._180
//
//        case .landscapeRight:
//            // UIInterfaceOrientation.landscapeRight ≡ UIDeviceOrientation.landscapeLeft
//            if isUsingFrontCamera {
//                return ._180
//            }
//            return ._0
//
//        case .unknown:
//            return mirrored ? ._270 : ._90
//
//        @unknown default:
//            return mirrored ? ._270 : ._90
//        }
//    }
//}
//
//// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
//
//extension CustomCameraVideoCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {
//
//    func captureOutput(
//        _ output: AVCaptureOutput,
//        didOutput sampleBuffer: CMSampleBuffer,
//        from connection: AVCaptureConnection
//    ) {
//        // Early validation for performance
//        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
//              CMSampleBufferIsValid(sampleBuffer),
//              CMSampleBufferDataIsReady(sampleBuffer),
//              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//            return
//        }
//
//        // Determine camera position from the active connection (cheaper and more
//        // reliable than scanning session inputs — handles mid-frame camera swaps).
//        let isUsingFrontCamera = connection.inputPorts
//            .compactMap { $0.input as? AVCaptureDeviceInput }
//            .first?.device.position == .front
//
//        let rotation = currentVideoRotation(isUsingFrontCamera: isUsingFrontCamera)
//
//        // Log the rotation only when it changes (not every frame) so we can see
//        // the transition as the user rotates the device without flooding the log.
//        if rotation != lastLoggedRotation {
//            lastLoggedRotation = rotation
//            logVerbose("Rotation → \(rotation.debugName) (frontCamera=\(isUsingFrontCamera), mirrored=\(connection.isVideoMirrored))")
//        }
//
//        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
//        let timeStampNs = Int64(
//            CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) *
//            Double(Constants.nanosecondsPerSecond)
//        )
//
//        let videoFrame = RTCVideoFrame(
//            buffer: rtcPixelBuffer,
//            rotation: rotation,
//            timeStampNs: timeStampNs
//        )
//
//        delegate?.capturer(self, didCapture: videoFrame)
//    }
//
//    func captureOutput(
//        _ output: AVCaptureOutput,
//        didDrop sampleBuffer: CMSampleBuffer,
//        from connection: AVCaptureConnection
//    ) {
//        logVerbose("Video frame dropped")
//    }
//}
//
//// MARK: - Notification Handling
//
//private extension CustomCameraVideoCapturer {
//
//    func addNotificationObservers() {
//        let center = NotificationCenter.default
//
//        // Interface orientation changes (scene / status bar)
//        center.addObserver(
//            self,
//            selector: #selector(orientationDidChange),
//            name: UIApplication.didChangeStatusBarOrientationNotification,
//            object: nil
//        )
//
//        // Physical device orientation changes — only observe when our strategy
//        // will actually read them. On a portrait-locked iPhone this observer
//        // would fire but its value would be ignored, so we skip it.
//        if shouldTrackDeviceOrientation {
//            center.addObserver(
//                self,
//                selector: #selector(deviceOrientationDidChange),
//                name: UIDevice.orientationDidChangeNotification,
//                object: nil
//            )
//        }
//
//        // Session notifications
//        let sessionNotifications: [(Notification.Name, Selector)] = [
//            (.AVCaptureSessionWasInterrupted, #selector(sessionWasInterrupted)),
//            (.AVCaptureSessionInterruptionEnded, #selector(sessionInterruptionEnded)),
//            (.AVCaptureSessionRuntimeError, #selector(sessionRuntimeError)),
//            (.AVCaptureSessionDidStartRunning, #selector(sessionDidStartRunning)),
//            (.AVCaptureSessionDidStopRunning, #selector(sessionDidStopRunning))
//        ]
//
//        sessionNotifications.forEach { notification, selector in
//            center.addObserver(
//                self,
//                selector: selector,
//                name: notification,
//                object: captureSession
//            )
//        }
//
//        // Application lifecycle
//        center.addObserver(
//            self,
//            selector: #selector(applicationDidBecomeActive),
//            name: UIApplication.didBecomeActiveNotification,
//            object: nil
//        )
//    }
//
//    @objc func orientationDidChange() {
//        let new = interfaceOrientation
//        currentInterfaceOrientation = new
//        log("Interface orientation → \(new.debugName)")
//    }
//
//    @objc func deviceOrientationDidChange() {
//        let new = UIDevice.current.orientation
//        // Ignore face-up / face-down / unknown — don't overwrite a good cached
//        // value with a useless one when the user sets the device down flat.
//        if new.isValidInterfaceOrientation {
//            currentDeviceOrientation = new
//            log("Device orientation → \(new.debugName)")
//        } else {
//            logVerbose("Device orientation ignored: \(new.debugName)")
//        }
//    }
//
//    @objc func sessionWasInterrupted(_ notification: Notification) {
//        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
//              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
//            log("Capture session interrupted: unknown reason")
//            return
//        }
//        log("Capture session interrupted: \(reason.description)")
//    }
//
//    @objc func sessionInterruptionEnded() {
//        log("Capture session interruption ended")
//    }
//
//    @objc func sessionRuntimeError(_ notification: Notification) {
//        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
//            log("Runtime error with no AVError payload")
//            return
//        }
//
//        log("ERROR: Capture session runtime error — \(error.localizedDescription) (code=\(error.code.rawValue))")
//
//        captureSessionQueue.async { [weak self] in
//            if error.code == .mediaServicesWereReset {
//                self?.handleRecoverableError()
//            } else {
//                self?.handleFatalError()
//            }
//        }
//    }
//
//    @objc func sessionDidStartRunning() {
//        log("Capture session started running")
//        captureSessionQueue.async { [weak self] in
//            self?.hasRetriedOnFatalError = false
//        }
//    }
//
//    @objc func sessionDidStopRunning() {
//        log("Capture session stopped running")
//    }
//
//    @objc func applicationDidBecomeActive() {
//        captureSessionQueue.async { [weak self] in
//            guard let self = self,
//                  case .running = self.captureState,
//                  !self.captureSession.isRunning else {
//                return
//            }
//
//            log("App became active — restarting capture session")
//            self.captureSession.startRunning()
//        }
//    }
//
//    func handleFatalError() {
//        guard !hasRetriedOnFatalError else {
//            log("ERROR: Previous fatal-error recovery failed, not retrying")
//            return
//        }
//
//        log("Attempting to recover from fatal error")
//        handleRecoverableError()
//        hasRetriedOnFatalError = true
//    }
//
//    func handleRecoverableError() {
//        guard case .running = captureState else { return }
//
//        log("Restarting capture session after recoverable error")
//        captureSession.startRunning()
//    }
//}
//
//// MARK: - Error Types
//
//private enum CaptureError: Error, LocalizedError {
//    case cannotAddInput
//    case deviceConfigurationFailed
//    case sessionSetupFailed
//
//    var errorDescription: String? {
//        switch self {
//        case .cannotAddInput:
//            return "Cannot add camera input to capture session"
//        case .deviceConfigurationFailed:
//            return "Failed to configure camera device"
//        case .sessionSetupFailed:
//            return "Failed to setup capture session"
//        }
//    }
//}

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
import os

// MARK: - Constants

private enum Constants {
    static let nanosecondsPerSecond: Int64 = 1_000_000_000
    static let logTag = "CameraCapturer"
    static let supportedPixelFormats: Set<FourCharCode> = [
        kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
}

/// Rotation strategy for the capturer.
///
/// * `.followInterface` — use the app's interface orientation only. Correct
///   when the app's UI is orientation-locked (e.g. iPhone locked to portrait):
///   the sent video matches what the user sees on screen, regardless of how
///   they physically hold the device.
/// * `.followDevice` — use the physical device orientation, falling back to
///   interface orientation. Correct when the UI rotates with the device
///   (e.g. iPad supporting all orientations).
/// * `.auto` — `.followInterface` on iPhone, `.followDevice` on iPad. Matches
///   the common "iPhone portrait-locked, iPad all-orientations" app setup.
enum CameraRotationStrategy {
    case followInterface
    case followDevice
    case auto
}

// MARK: - Logging

/// Lightweight tagged logger. All logs go through here so they can be filtered
/// in the Xcode console with "[CameraCapturer]" and silenced in one place.
@inline(__always)
private func log(_ message: @autoclosure () -> String,
                 function: String = #function) {
    print("[\(Constants.logTag)] \(function) — \(message())")
}

@inline(__always)
private func logVerbose(_ message: @autoclosure () -> String,
                        function: String = #function) {
    #if DEBUG
    print("[\(Constants.logTag)] \(function) — \(message())")
    #endif
}

// MARK: - UnfairLock

/// Thin Swift wrapper around `os_unfair_lock`. Acquiring is ~20ns uncontended
/// — dramatically cheaper than a GCD `sync` dispatch — which matters when we
/// read state on every captured frame at 30–60fps.
private final class UnfairLock {

    private let _ptr: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _ptr = UnsafeMutablePointer.allocate(capacity: 1)
        _ptr.initialize(to: os_unfair_lock())
    }

    deinit {
        _ptr.deinitialize(count: 1)
        _ptr.deallocate()
    }

    @inline(__always)
    func lock()   { os_unfair_lock_lock(_ptr) }

    @inline(__always)
    func unlock() { os_unfair_lock_unlock(_ptr) }

    @inline(__always)
    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(_ptr)
        defer { os_unfair_lock_unlock(_ptr) }
        return body()
    }
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

private extension UIDeviceOrientation {
    var debugName: String {
        switch self {
        case .unknown: return "unknown"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

private extension UIInterfaceOrientation {
    var debugName: String {
        switch self {
        case .unknown: return "unknown"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

private extension RTCVideoRotation {
    var debugName: String {
        switch self {
        case ._0: return "0°"
        case ._90: return "90°"
        case ._180: return "180°"
        case ._270: return "270°"
        @unknown default: return "unknown(\(rawValue))"
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

        var debugName: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .running: return "running"
            case .stopping: return "stopping"
            case .error(let e): return "error(\(e.localizedDescription))"
            }
        }
    }

    // MARK: - Public Configuration

    /// How to choose rotation for captured frames. Defaults to `.auto` which
    /// means "interface orientation on iPhone, device orientation on iPad" —
    /// matching an app that locks iPhone to portrait and supports all
    /// orientations on iPad. See `CameraRotationStrategy` for details.
    var rotationStrategy: CameraRotationStrategy = .auto {
        didSet {
            log("rotationStrategy set to \(rotationStrategy)")
            refreshCachedRotation()
        }
    }

    /// When `true`, the front camera output is horizontally mirrored — the
    /// user (and any peer rendering these frames) sees the image the same way
    /// the iOS Camera app shows its selfie preview: raising your right hand
    /// shows on the right of the frame, as in a mirror.
    ///
    /// Standard WebRTC convention is to leave this `false` (send unmirrored
    /// frames to the remote peer, and apply a horizontal flip only on the
    /// local preview view). Flip this back to `false` if the remote peer is
    /// seeing you mirrored (text backwards) and that's not what you want.
    var mirrorsFrontCamera: Bool = true {
        didSet {
            log("mirrorsFrontCamera set to \(mirrorsFrontCamera)")
            captureSessionQueue.async { [weak self] in
                self?.applyVideoMirroring()
            }
            refreshCachedRotation()
        }
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

    // Track last-logged rotation so we only log when it actually changes,
    // not 30 times a second.
    private var lastLoggedRotation: RTCVideoRotation?

    // All shared state below is protected by `stateLock`. We keep a single
    // precomputed `_cachedRotation` that the frame callback reads — computed
    // once per orientation / camera / mirror change, not per frame.
    private let stateLock = UnfairLock()

    private var _currentInterfaceOrientation: UIInterfaceOrientation = .unknown
    private var _currentDeviceOrientation: UIDeviceOrientation = .unknown
    private var _isFrontCameraCached: Bool = false
    private var _cachedRotation: RTCVideoRotation = ._90

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

        // Frame processing uses .userInteractive because it's on the critical
        // path to the encoder — every microsecond spent here is latency a
        // remote viewer experiences. `.userInteractive` gets the shortest
        // scheduling latency the system offers.
        self.frameProcessingQueue = DispatchQueue(
            label: "org.webrtc.cameravideocapturer.frameprocessing",
            qos: .userInteractive,
            attributes: [],
            autoreleaseFrequency: .workItem
        )

        super.init(delegate: delegate)

        log("init — idiom=\(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone")")

        // Initialize orientation. We only turn on device-orientation
        // notifications if our resolved strategy will actually read them,
        // i.e. on iPad (with .auto) or any device under .followDevice.
        // This avoids waking the accelerometer on portrait-locked iPhones
        // where device orientation is ignored anyway.

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let iface = self.interfaceOrientation

            if self.shouldTrackDeviceOrientation {

                if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    log("Began generating device orientation notifications")
                }

                let device = UIDevice.current.orientation
                self.stateLock.withLock {
                    self._currentInterfaceOrientation = iface
                    if device.isValidInterfaceOrientation {
                        self._currentDeviceOrientation = device
                    }
                }

                log("Initial orientation — device=\(device.debugName), interface=\(iface.debugName)")

            } else {

                self.stateLock.withLock {
                    self._currentInterfaceOrientation = iface
                }
                log("Initial orientation — interface=\(iface.debugName) (device orientation not tracked on this idiom)")
            }

            self.refreshCachedRotation()
        }

        setupCaptureSession()

        addNotificationObservers()
    }

    deinit {

        log("deinit")
        NotificationCenter.default.removeObserver(self)

        // Pair beginGeneratingDeviceOrientationNotifications only if we
        // actually started it. If another component in the app also depends
        // on these notifications, consider centralizing this with a refcount.
        if shouldTrackDeviceOrientation {
            DispatchQueue.main.async {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }

        // Ensure cleanup happens synchronously without weak reference
        cleanupCaptureSession()
    }

    // MARK: - Public API

    func startCapture(
        with device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        fps: Int
    ) {

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        log("startCapture requested — device=\(device.localizedName), position=\(device.position.rawValue), \(dims.width)x\(dims.height) @ \(fps)fps")

        captureSessionQueue.async { [weak self] in
            self?.performStartCapture(device: device, format: format, fps: fps)
        }
    }

    func stopCapture() {

        log("stopCapture requested")
        captureSessionQueue.async { [weak self] in
            self?.performStopCapture()
        }
    }

    // MARK: Current Camera

    func isFrontCamera() -> Bool {
        // Fast path: read the cache. Fall back to session inspection if the
        // cache hasn't been primed yet (shouldn't happen once a capture has
        // started, but cheap to be defensive).
        let cached = stateLock.withLock { _isFrontCameraCached }
        if cached { return true }

        return captureSession.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .contains { $0.device.position == .front }
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
            log("ERROR: Cannot add video data output to capture session")
            return
        }

        captureSession.addOutput(videoDataOutput)
        log("Capture session configured — preset=inputPriority, output=videoDataOutput")
    }

    private func configureVideoDataOutput() {

        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        // Never hold onto a frame that's already too old to ship — critical
        // for a live call where stale frames just make jitter worse.
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: frameProcessingQueue)
    }

    private func performStartCapture(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {

        log("performStartCapture called — current state: \(captureState.debugName)")  // ← add this
          
        
        guard case .idle = captureState else {
            log("Cannot start capture: current state is \(captureState.debugName)")
            return
        }

        captureState = .starting
        log("State → starting")

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            try configureDevice(device, format: format, fps: fps)
            try configureCaptureSessionInput(for: device)

            // Mirroring + stabilization can only be set after the connection
            // exists (i.e. after the input is added above).
            applyVideoMirroring()
            applyConnectionPerformanceSettings()

            captureSession.startRunning()

            // Update the camera-position cache + recompute rotation now that
            // we know which camera is active.
            stateLock.withLock {
                _isFrontCameraCached = (device.position == .front)
            }
            refreshCachedRotation()

            captureState = .running
            currentDevice = device
            lastLoggedRotation = nil
            log("State → running — camera is \(device.position == .front ? "FRONT" : "BACK")")

        } catch {
            captureState = .error(error)
            log("ERROR: Failed to start capture — \(error.localizedDescription)")
        }
    }

    private func performStopCapture() {

        guard case .running = captureState else {
            log("Cannot stop capture: current state is \(captureState.debugName)")
            return
        }

        captureState = .stopping
        log("State → stopping")

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
        lastLoggedRotation = nil
        stateLock.withLock { _isFrontCameraCached = false }

        // Re-configure video output for future use
        configureVideoDataOutput()

        captureState = .idle
        log("State → idle")
    }

    private func configureDevice(_ device: AVCaptureDevice,
                                 format: AVCaptureDevice.Format,
                                 fps: Int) throws {

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

        log("Device configured — lowLightBoost=\(device.isLowLightBoostSupported), focus=\(device.focusMode.rawValue), exposure=\(device.exposureMode.rawValue)")
    }

    private func configureCaptureSessionInput(for device: AVCaptureDevice) throws {

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove existing input
        if let currentInput = currentDeviceInput {
            captureSession.removeInput(currentInput)
            log("Removed existing input for \(currentInput.device.localizedName)")
        }

        // Add new input
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(deviceInput) else {
            log("ERROR: Cannot add input for \(device.localizedName)")
            throw CaptureError.cannotAddInput
        }

        captureSession.addInput(deviceInput)
        currentDeviceInput = deviceInput
        log("Added input for \(device.localizedName)")
    }

    /// Applies mirroring policy to the active video connection.
    ///
    /// Front camera: mirror if `mirrorsFrontCamera` is true — matches the iOS
    /// Camera app selfie preview behavior. The user sees a natural "mirror"
    /// image (raising your right hand shows the hand on the right of the frame).
    ///
    /// Back camera: never mirror.
    private func applyVideoMirroring() {

        guard let connection = videoDataOutput.connection(with: .video) else {
            log("applyVideoMirroring: no video connection yet (will apply after input is added)")
            return
        }

        let isFront = currentDeviceInput?.device.position == .front
        let shouldMirror = isFront && mirrorsFrontCamera

        // Must turn off automatic adjustment before manual override.
        if connection.isVideoMirroringSupported {

            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = shouldMirror
            log("Mirroring applied — front=\(isFront), mirror=\(shouldMirror)")

        } else {

            log("Mirroring not supported on this connection")
        }
    }

    /// Applies latency-sensitive connection settings. Video stabilization
    /// buffers frames internally (1–2 frame delay) — great for recording,
    /// bad for a live call. Disabling it is the single biggest capture-side
    /// latency win on recent iPhones where stabilization is on by default.
    private func applyConnectionPerformanceSettings() {

        guard let connection = videoDataOutput.connection(with: .video) else {
            return
        }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
            log("Video stabilization disabled for low-latency capture")
        }
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

    // MARK: - Orientation Resolution

    /// Finds the "most correct" interface orientation for the app.
    ///
    /// On iPad multi-tasking (Split View / Slide Over), multiple scenes can be
    /// connected simultaneously and our scene may be `foregroundInactive` while
    /// still visible. We prefer the scene hosting the key window, then any
    /// foreground-active scene, then any foreground-inactive scene, then any
    /// connected scene.
    private var interfaceOrientation: UIInterfaceOrientation {

        if #available(iOS 13.0, *) {

            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }

            if let keyScene = scenes.first(where: { scene in
                scene.windows.contains(where: { $0.isKeyWindow })
            }) {
                return keyScene.interfaceOrientation
            }
            if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
                return active.interfaceOrientation
            }
            if let inactive = scenes.first(where: { $0.activationState == .foregroundInactive }) {
                return inactive.interfaceOrientation
            }
            return scenes.first?.interfaceOrientation ?? .unknown

        } else {
            return UIApplication.shared.statusBarOrientation
        }
    }

    /// The strategy actually in effect (resolves `.auto` to concrete value).
    private var effectiveStrategy: CameraRotationStrategy {

        switch rotationStrategy {
        case .followInterface, .followDevice:
            return rotationStrategy
        case .auto:
            return UIDevice.current.userInterfaceIdiom == .pad ? .followDevice : .followInterface
        }
    }

    /// Whether we need `UIDevice.current.orientation` to be meaningful.
    /// Only true when the effective strategy reads it.
    private var shouldTrackDeviceOrientation: Bool {

        return effectiveStrategy == .followDevice
    }

    /// Recomputes `_cachedRotation` from the current orientation + camera
    /// state, so the frame-callback hot path can read a single precomputed
    /// value instead of walking a switch/fallback chain every frame.
    ///
    /// Safe to call from any thread. Called on every orientation change,
    /// camera swap, and mirror/strategy change.
    private func refreshCachedRotation() {

        // Snapshot inputs under the lock, then compute lock-free, then
        // store under the lock. This keeps the critical section tiny.
        let (iface, device, isFront) = stateLock.withLock {
            (_currentInterfaceOrientation, _currentDeviceOrientation, _isFrontCameraCached)
        }

        let strategy = effectiveStrategy
        let mirrored = isFront && mirrorsFrontCamera

        let rotation: RTCVideoRotation
        switch strategy {
        case .followInterface:
            rotation = rotationFromInterfaceOrientation(
                iface,
                isUsingFrontCamera: isFront,
                mirrored: mirrored
            )

        case .followDevice:
            if device.isValidInterfaceOrientation {
                rotation = rotationFromDeviceOrientation(
                    device,
                    isUsingFrontCamera: isFront,
                    mirrored: mirrored
                )
            } else {
                // Fallback: device orientation wasn't valid (face-up / face-down
                // / unknown). Use interface orientation instead.
                rotation = rotationFromInterfaceOrientation(
                    iface,
                    isUsingFrontCamera: isFront,
                    mirrored: mirrored
                )
            }

        case .auto:
            // effectiveStrategy already resolved .auto; unreachable.
            rotation = mirrored ? ._270 : ._90
        }

        stateLock.withLock { _cachedRotation = rotation }
    }

    /// Behavior of the rotation math (preserved from the original):
    ///
    /// Rotation depends on BOTH camera position and whether the capture
    /// connection is mirroring:
    ///
    /// * Back camera (no mirror): standard rotations.
    /// * Front camera, NOT mirrored at capture: landscape rotations are
    ///   inverted by 180° because the front sensor is mounted rotated 180°
    ///   relative to the back sensor. Portrait rotations match back camera.
    /// * Front camera, MIRRORED at capture (`isVideoMirrored = true`):
    ///   `isVideoMirrored` flips the buffer along the sensor's landscape-
    ///   native horizontal axis. Combined with a 90°/270° display rotation,
    ///   that horizontal axis becomes the display's vertical axis — so the
    ///   mirror becomes an upside-down flip. We compensate with a different
    ///   rotation in every orientation.
    ///
    /// Note the inversion between the two enums:
    ///   UIInterfaceOrientation.landscapeLeft  ≡ UIDeviceOrientation.landscapeRight
    ///   UIInterfaceOrientation.landscapeRight ≡ UIDeviceOrientation.landscapeLeft
    private func rotationFromDeviceOrientation(
        _ orientation: UIDeviceOrientation,
        isUsingFrontCamera: Bool,
        mirrored: Bool
    ) -> RTCVideoRotation {
        switch orientation {
        case .portrait:
            return mirrored ? ._270 : ._90

        case .portraitUpsideDown:
            return mirrored ? ._90 : ._270

        case .landscapeLeft:
            // Device rotated left → home indicator / Dynamic Island on the RIGHT.
            if isUsingFrontCamera {
                return ._180
            }
            return ._0

        case .landscapeRight:
            // Device rotated right → home indicator / Dynamic Island on the LEFT.
            if isUsingFrontCamera {
                return ._0
            }
            return ._180

        default:
            return mirrored ? ._270 : ._90
        }
    }

    private func rotationFromInterfaceOrientation(
        _ orientation: UIInterfaceOrientation,
        isUsingFrontCamera: Bool,
        mirrored: Bool
    ) -> RTCVideoRotation {
        switch orientation {
        case .portrait:
            return mirrored ? ._270 : ._90

        case .portraitUpsideDown:
            return mirrored ? ._90 : ._270

        case .landscapeLeft:
            // UIInterfaceOrientation.landscapeLeft ≡ UIDeviceOrientation.landscapeRight
            if isUsingFrontCamera {
                return ._0
            }
            return ._180

        case .landscapeRight:
            // UIInterfaceOrientation.landscapeRight ≡ UIDeviceOrientation.landscapeLeft
            if isUsingFrontCamera {
                return ._180
            }
            return ._0

        case .unknown:
            return mirrored ? ._270 : ._90

        @unknown default:
            return mirrored ? ._270 : ._90
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
        // Fast-path validation — these are all cheap C calls.
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Read precomputed rotation + camera state under a single lock
        // acquisition (~20ns). The original code did a GCD sync dispatch
        // here on every frame plus rebuilt an array from connection inputs.
        let rotation: RTCVideoRotation
        let isFront: Bool
        stateLock.lock()
        rotation = _cachedRotation
        isFront  = _isFrontCameraCached
        stateLock.unlock()

        // Log rotation only on change — keeps the console clean at 30fps.
        if rotation != lastLoggedRotation {
            lastLoggedRotation = rotation
            logVerbose("Rotation → \(rotation.debugName) (frontCamera=\(isFront), mirrored=\(connection.isVideoMirrored))")
        }

        // Zero-copy wrap of the pixel buffer for WebRTC.
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

        // Integer-precise ns conversion. Avoids the Float64 round-trip of
        // `CMTimeGetSeconds() * 1e9` and won't lose precision over a long
        // session.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = CMTimeConvertScale(
            pts,
            timescale: CMTimeScale(Constants.nanosecondsPerSecond),
            method: .roundTowardZero
        )
        let timeStampNs = ptsNs.value

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
        logVerbose("Video frame dropped")
    }
}

// MARK: - Notification Handling

private extension CustomCameraVideoCapturer {

    func addNotificationObservers() {
        let center = NotificationCenter.default

        // Interface orientation changes (scene / status bar)
        center.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIApplication.didChangeStatusBarOrientationNotification,
            object: nil
        )

        // Physical device orientation changes — only observe when our strategy
        // will actually read them. On a portrait-locked iPhone this observer
        // would fire but its value would be ignored, so we skip it.
        if shouldTrackDeviceOrientation {
            center.addObserver(
                self,
                selector: #selector(deviceOrientationDidChange),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
        }

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
        let new = interfaceOrientation
        stateLock.withLock { _currentInterfaceOrientation = new }
        refreshCachedRotation()
        log("Interface orientation → \(new.debugName)")
    }

    @objc func deviceOrientationDidChange() {
        let new = UIDevice.current.orientation
        // Ignore face-up / face-down / unknown — don't overwrite a good cached
        // value with a useless one when the user sets the device down flat.
        if new.isValidInterfaceOrientation {
            stateLock.withLock { _currentDeviceOrientation = new }
            refreshCachedRotation()
            log("Device orientation → \(new.debugName)")
        } else {
            logVerbose("Device orientation ignored: \(new.debugName)")
        }
    }

    @objc func sessionWasInterrupted(_ notification: Notification) {
        
        guard let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            log("Capture session interrupted: unknown reason")
            return
        }
        log("Capture session interrupted: \(reason.description)")
        print("⚠️ [CameraCapturer] sessionWasInterrupted reason=\(reasonValue)")
    }

    @objc func sessionInterruptionEnded() {
        log("Capture session interruption ended")
        print("✅ [CameraCapturer] sessionInterruptionEnded")
    }

    @objc func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            log("Runtime error with no AVError payload")
            return
        }

        log("ERROR: Capture session runtime error — \(error.localizedDescription) (code=\(error.code.rawValue))")

        captureSessionQueue.async { [weak self] in
            if error.code == .mediaServicesWereReset {
                self?.handleRecoverableError()
            } else {
                self?.handleFatalError()
            }
        }
    }

    @objc func sessionDidStartRunning() {
        log("Capture session started running")
        captureSessionQueue.async { [weak self] in
            self?.hasRetriedOnFatalError = false
        }
    }

    @objc func sessionDidStopRunning() {
        log("Capture session stopped running")
    }

    @objc func applicationDidBecomeActive() {
        captureSessionQueue.async { [weak self] in
            guard let self = self,
                  case .running = self.captureState,
                  !self.captureSession.isRunning else {
                return
            }

            log("App became active — restarting capture session")
            self.captureSession.startRunning()
        }
    }

    func handleFatalError() {
        guard !hasRetriedOnFatalError else {
            log("ERROR: Previous fatal-error recovery failed, not retrying")
            return
        }

        log("Attempting to recover from fatal error")
        handleRecoverableError()
        hasRetriedOnFatalError = true
    }

    func handleRecoverableError() {
        guard case .running = captureState else { return }

        log("Restarting capture session after recoverable error")
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
