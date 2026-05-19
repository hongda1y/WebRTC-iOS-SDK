//
//  StreamContentType.swift
//  WebRTCiOSSDK
//
//  Created by Hong Daly on 19/05/2026.
//


//
//  StreamContentType.swift
//  WebRTCiOSSDK
//
//  Created by Hong Daly on 27/04/2026.
//


//
//  AdaptiveVideoStreamer.swift
//
//  Watches network conditions + WebRTC stats and adjusts the outgoing
//  video sender's bitrate / framerate / resolution to keep latency low
//  for the remote viewer.
//

import Foundation
import Network
import WebRTC
import UIKit

// MARK: - Content type

/// Hint for what kind of content is being streamed. Different content needs
/// different trade-offs:
///
///  * `.camera` — talking heads, faces. Motion is mild; resolution can drop
///    quite far before the user notices, but framerate stutter is glaring.
///  * `.screenShare` — UI / text / slides. Detail matters more than motion;
///    we prefer keeping resolution and dropping framerate.
///  * `.general` — sensible mixed defaults. Used when the caller doesn't
///    care to specify (e.g. a generic publishing client).
enum StreamContentType {
    case camera
    case screenShare
    case general
}

// MARK: - Profile

struct VideoStreamingProfile: Equatable {

    let name: String
    let maxBitrateBps: Int
    let maxFramerate: Int
    let scaleResolutionDownBy: Double

    // -------- Camera ladder (talking heads) --------
    static let cameraExcellent = VideoStreamingProfile(name: "camera-excellent",
                                                       maxBitrateBps: 2_500_000,
                                                       maxFramerate: 30,
                                                       scaleResolutionDownBy: 1.0)
    static let cameraGood      = VideoStreamingProfile(name: "camera-good",
                                                       maxBitrateBps: 1_200_000,
                                                       maxFramerate: 30,
                                                       scaleResolutionDownBy: 1.5)
    static let cameraFair      = VideoStreamingProfile(name: "camera-fair",
                                                       maxBitrateBps: 600_000,
                                                       maxFramerate: 25,
                                                       scaleResolutionDownBy: 2.0)
    static let cameraPoor      = VideoStreamingProfile(name: "camera-poor",
                                                       maxBitrateBps: 250_000,
                                                       maxFramerate: 15,
                                                       scaleResolutionDownBy: 3.0)
    static let cameraCritical  = VideoStreamingProfile(name: "camera-critical",
                                                       maxBitrateBps: 120_000,
                                                       maxFramerate: 10,
                                                       scaleResolutionDownBy: 4.0)

    // -------- Screen-share ladder (keep res, drop fps + bitrate) --------
    // IMPORTANT: scaleResolutionDownBy stays at 1.0 across the entire
    // screen-share ladder. iPad screen capture produces dimensions like
    // 2048×2732, and dividing those by 1.25/1.5/etc. yields non-multiple-
    // of-16 values that crash the iOS H.264 hardware encoder. For screen
    // share we adapt by reducing fps + bitrate only.
    static let screenExcellent = VideoStreamingProfile(name: "screen-excellent",
                                                       maxBitrateBps: 6_000_000,
                                                       maxFramerate: 15,
                                                       scaleResolutionDownBy: 1.0)
    static let screenGood      = VideoStreamingProfile(name: "screen-good",
                                                       maxBitrateBps: 4_000_000,
                                                       maxFramerate: 15,
                                                       scaleResolutionDownBy: 1.0)
    static let screenFair      = VideoStreamingProfile(name: "screen-fair",
                                                       maxBitrateBps: 2_000_000,
                                                       maxFramerate: 12,
                                                       scaleResolutionDownBy: 1.0)
    static let screenPoor      = VideoStreamingProfile(name: "screen-poor",
                                                       maxBitrateBps: 800_000,
                                                       maxFramerate: 8,
                                                       scaleResolutionDownBy: 1.0)
    static let screenCritical  = VideoStreamingProfile(name: "screen-critical",
                                                       maxBitrateBps: 400_000,
                                                       maxFramerate: 5,
                                                       scaleResolutionDownBy: 1.0)

    // -------- General ladder (balanced — used for "mixed / unknown") --------
    static let generalExcellent = VideoStreamingProfile(name: "general-excellent",
                                                        maxBitrateBps: 2_200_000,
                                                        maxFramerate: 30,
                                                        scaleResolutionDownBy: 1.0)
    static let generalGood      = VideoStreamingProfile(name: "general-good",
                                                        maxBitrateBps: 1_100_000,
                                                        maxFramerate: 25,
                                                        scaleResolutionDownBy: 1.5)
    static let generalFair      = VideoStreamingProfile(name: "general-fair",
                                                        maxBitrateBps: 550_000,
                                                        maxFramerate: 20,
                                                        scaleResolutionDownBy: 2.0)
    static let generalPoor      = VideoStreamingProfile(name: "general-poor",
                                                        maxBitrateBps: 220_000,
                                                        maxFramerate: 12,
                                                        scaleResolutionDownBy: 3.0)
    static let generalCritical  = VideoStreamingProfile(name: "general-critical",
                                                        maxBitrateBps: 110_000,
                                                        maxFramerate: 8,
                                                        scaleResolutionDownBy: 4.0)

    /// Worst → best ladder for a given content type.
    static func ladder(for contentType: StreamContentType) -> [VideoStreamingProfile] {
        switch contentType {
        case .camera:
            return [.cameraCritical, .cameraPoor, .cameraFair, .cameraGood, .cameraExcellent]
        case .screenShare:
            return [.screenCritical, .screenPoor, .screenFair, .screenGood, .screenExcellent]
        case .general:
            return [.generalCritical, .generalPoor, .generalFair, .generalGood, .generalExcellent]
        }
    }
}

// MARK: - Quality classification

private enum NetworkQualityClass: Int, Comparable {
    case critical = 0
    case poor     = 1
    case fair     = 2
    case good     = 3
    case excellent = 4

    static func < (lhs: NetworkQualityClass, rhs: NetworkQualityClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Adaptive streamer

final class AdaptiveVideoStreamer {

    // MARK: Private
    private let deviceTier: DeviceCapabilityTier
    private var thermalState: ProcessInfo.ThermalState
    private var isLowPowerMode: Bool
    private var thermalObserver: NSObjectProtocol?
    private var lowPowerObserver: NSObjectProtocol?

    // MARK: Public knobs

    var pollInterval: TimeInterval = 2.0
    var downgradeThreshold = 2
    var upgradeThreshold = 4

    var bitrateCeilingBps: Int? {
        didSet { workQueue.async { [weak self] in self?.reapplyCurrent() } }
    }

    var contentType: StreamContentType {
        didSet {
            workQueue.async { [weak self] in
                guard let self = self else { return }
                self.activeLadder = VideoStreamingProfile.ladder(for: self.contentType)
                let current = self.currentClass
                let target = self.activeLadder[current.rawValue]
                self.consecutiveBetter = 0
                self.consecutiveWorse = 0
                self.pendingTargetClass = nil
                self.apply(profile: target, reason: "contentType=\(self.contentType)")
            }
        }
    }

    var onProfileChange: ((VideoStreamingProfile) -> Void)?

    private(set) var currentProfile: VideoStreamingProfile

    // MARK: Private state

    private weak var peerConnection: RTCPeerConnection?
    private weak var videoSender: RTCRtpSender?

    private let workQueue = DispatchQueue(
        label: "com.app.adaptive-video-streamer",
        qos: .utility
    )

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.app.adaptive-video-streamer.path")
    private var currentInterfaceType: NWInterface.InterfaceType?
    private var isPathSatisfied = true

    private var pollTimer: DispatchSourceTimer?

    private var activeLadder: [VideoStreamingProfile]
    private var currentClass: NetworkQualityClass = .good

    private var consecutiveBetter = 0
    private var consecutiveWorse  = 0
    private var pendingTargetClass: NetworkQualityClass?

    private var lastBytesSent: Int64 = 0
    private var lastBytesSentTime: CFAbsoluteTime = 0
    private var lastPacketsLost: Int64 = 0
    private var lastPacketsSent: Int64 = 0

    // MARK: Init

    init(peerConnection: RTCPeerConnection,
         videoSender: RTCRtpSender,
         contentType: StreamContentType = .general) {
        self.peerConnection = peerConnection
        self.videoSender = videoSender
        self.contentType = contentType
        self.activeLadder = VideoStreamingProfile.ladder(for: contentType)
        self.currentProfile = activeLadder[NetworkQualityClass.good.rawValue]
        self.deviceTier = DeviceCapability.current
        self.thermalState = ProcessInfo.processInfo.thermalState
        self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        print("[AdaptiveStreamer] device tier=\(deviceTier) thermal=\(thermalState.rawValue) lowPower=\(isLowPowerMode)")
    }

    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        startPathMonitoring()
        startPolling()
        startThermalMonitoring()
    }

    private func startThermalMonitoring() {
        let center = NotificationCenter.default

        thermalObserver = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            self?.workQueue.async {
                guard let self = self else { return }
                self.thermalState = state
                print("[AdaptiveStreamer] thermal → \(state.rawValue)")
                self.reapplyCurrent()
            }
        }

        lowPowerObserver = center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.workQueue.async {
                guard let self = self else { return }
                self.isLowPowerMode = low
                print("[AdaptiveStreamer] lowPower → \(low)")
                self.reapplyCurrent()
            }
        }
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        pathMonitor.cancel()

        if let t = thermalObserver { NotificationCenter.default.removeObserver(t) }
        if let l = lowPowerObserver { NotificationCenter.default.removeObserver(l) }
        thermalObserver = nil
        lowPowerObserver = nil
    }

    // MARK: NWPathMonitor

    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let interface = path.availableInterfaces.first?.type
            self.workQueue.async {
                self.currentInterfaceType = interface
                self.isPathSatisfied = (path.status == .satisfied)
                self.applyInitialProfileForInterface(interface, expensive: path.isExpensive)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func applyInitialProfileForInterface(_ type: NWInterface.InterfaceType?, expensive: Bool) {
        let target: NetworkQualityClass
        switch type {
        case .wifi, .wiredEthernet:
            target = .good
        case .cellular:
            target = expensive ? .fair : .good
        case .loopback, .other, .none:
            return
        @unknown default:
            return
        }
        consecutiveBetter = 0
        consecutiveWorse = 0
        pendingTargetClass = nil
        currentClass = target
        apply(profile: activeLadder[target.rawValue],
              reason: "interface=\(type.map(String.init(describing:)) ?? "?")")
    }

    // MARK: Stats polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + pollInterval,
                       repeating: pollInterval,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.pollStats() }
        timer.resume()
        pollTimer = timer
    }

    private func pollStats() {
        guard let pc = peerConnection else { return }
        // Capture pc weakly inside the callback too — protects against the
        // peer connection being torn down while a stats query is in flight.
        pc.statistics { [weak self, weak pc] report in
            guard let self = self, pc != nil else { return }
            self.workQueue.async { self.consume(report: report) }
        }
    }

    private func consume(report: RTCStatisticsReport) {

        var availableOutgoingBitrate: Double?
        var rttSeconds: Double?
        var packetsLost: Int64 = 0
        var packetsSent: Int64 = 0
        var bytesSent: Int64 = 0
        var qualityLimitationReason: String?
        var frameWidth: Int = 0
        var frameHeight: Int = 0
        var framesPerSecond: Double = 0
        var encoderImplementation: String?
        var nackCount: Int64 = 0
        var firCount: Int64 = 0
        var pliCount: Int64 = 0

        for (_, stat) in report.statistics {
            switch stat.type {

            case "candidate-pair":
                if let nominated = stat.values["nominated"] as? Bool, nominated,
                   let state = stat.values["state"] as? String, state == "succeeded" {
                    if let abr = stat.values["availableOutgoingBitrate"] as? Double {
                        availableOutgoingBitrate = abr
                    }
                    if let rtt = stat.values["currentRoundTripTime"] as? Double {
                        rttSeconds = rtt
                    }
                }

            case "outbound-rtp":
                guard (stat.values["kind"] as? String) == "video" else { continue }

                if let bytes = stat.values["bytesSent"] as? Int64 {
                    bytesSent = max(bytesSent, bytes)
                } else if let bytes = stat.values["bytesSent"] as? UInt64 {
                    bytesSent = max(bytesSent, Int64(bytes))
                }
                if let sent = stat.values["packetsSent"] as? Int64 {
                    packetsSent = max(packetsSent, sent)
                }
                if let reason = stat.values["qualityLimitationReason"] as? String {
                    qualityLimitationReason = reason
                }
                if let w = stat.values["frameWidth"] as? Int { frameWidth = max(frameWidth, w) }
                if let h = stat.values["frameHeight"] as? Int { frameHeight = max(frameHeight, h) }
                if let fps = stat.values["framesPerSecond"] as? Double { framesPerSecond = fps }
                if let impl = stat.values["encoderImplementation"] as? String {
                    encoderImplementation = impl
                }
                if let n = stat.values["nackCount"] as? Int64 { nackCount = max(nackCount, n) }
                if let f = stat.values["firCount"] as? Int64 { firCount = max(firCount, f) }
                if let p = stat.values["pliCount"] as? Int64 { pliCount = max(pliCount, p) }

            case "remote-inbound-rtp":
                guard (stat.values["kind"] as? String) == "video" else { continue }
                if let lost = stat.values["packetsLost"] as? Int64 {
                    packetsLost = max(packetsLost, lost)
                }
                if let rtt = stat.values["roundTripTime"] as? Double, rttSeconds == nil {
                    rttSeconds = rtt
                }

            default:
                break
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastBytesSentTime == 0 ? pollInterval : now - lastBytesSentTime
        let measuredBitrate: Double = dt > 0 ? Double(bytesSent - lastBytesSent) * 8.0 / dt : 0
        lastBytesSent = bytesSent
        lastBytesSentTime = now

        let lostDelta = max(0, packetsLost - lastPacketsLost)
        let sentDelta = max(0, packetsSent - lastPacketsSent)
        lastPacketsLost = packetsLost
        lastPacketsSent = packetsSent

        let lossRate: Double = sentDelta > 0
            ? Double(lostDelta) / Double(sentDelta + lostDelta)
            : 0

        // Diagnostic per-poll summary.
        let abrKbps = (availableOutgoingBitrate ?? 0) / 1000
        let actualKbps = measuredBitrate / 1000
        let rttMs = (rttSeconds ?? 0) * 1000
        let lossPct = lossRate * 100
        let encoder = encoderImplementation ?? "?"

        print(String(
            format: "[Stats] %dx%d @ %.1ffps  actual=%.0fkbps  abr=%.0fkbps  "
                  + "limit=%@  loss=%.2f%%  rtt=%.0fms  enc=%@  "
                  + "profile=%@(cap %dkbps/%dfps/x%.1f)  "
                  + "nack=%lld fir=%lld pli=%lld",
            frameWidth, frameHeight, framesPerSecond,
            actualKbps, abrKbps,
            qualityLimitationReason ?? "none",
            lossPct, rttMs,
            encoder,
            currentProfile.name,
            currentProfile.maxBitrateBps / 1000,
            currentProfile.maxFramerate,
            currentProfile.scaleResolutionDownBy,
            nackCount, firCount, pliCount
        ))

        let target = classify(
            availableOutgoingBitrate: availableOutgoingBitrate,
            measuredBitrate: measuredBitrate,
            rttSeconds: rttSeconds,
            lossRate: lossRate,
            qualityLimitationReason: qualityLimitationReason
        )

        applyHysteresis(target: target)
    }

    private func classify(
        availableOutgoingBitrate abr: Double?,
        measuredBitrate: Double,
        rttSeconds: Double?,
        lossRate: Double,
        qualityLimitationReason: String?
    ) -> NetworkQualityClass {

        if lossRate > 0.10 || (rttSeconds ?? 0) > 0.6 { return .critical }
        if lossRate > 0.05 || (rttSeconds ?? 0) > 0.4 { return .poor }

        if qualityLimitationReason == "bandwidth" {
            return NetworkQualityClass(rawValue: max(0, currentClass.rawValue - 1)) ?? .poor
        }

        if let abr = abr {
            switch abr {
            case ..<200_000:            return .critical
            case 200_000..<500_000:     return .poor
            case 500_000..<1_000_000:   return .fair
            case 1_000_000..<2_000_000: return .good
            default:                    return .excellent
            }
        }

        if measuredBitrate > 1_500_000 && lossRate < 0.01 { return .good }
        if measuredBitrate > 600_000 { return .fair }
        return .fair
    }

    // MARK: Hysteresis

    private func applyHysteresis(target: NetworkQualityClass) {
        if target == currentClass {
            consecutiveBetter = 0
            consecutiveWorse = 0
            pendingTargetClass = nil
            return
        }

        if target < currentClass {
            if pendingTargetClass != target {
                pendingTargetClass = target
                consecutiveWorse = 1
            } else {
                consecutiveWorse += 1
            }
            consecutiveBetter = 0

            if consecutiveWorse >= downgradeThreshold {
                let stepped = NetworkQualityClass(
                    rawValue: max(target.rawValue, currentClass.rawValue - 1)
                ) ?? target
                currentClass = stepped
                apply(profile: activeLadder[stepped.rawValue],
                      reason: "downgrade (target=\(target))")
                consecutiveWorse = 0
                pendingTargetClass = nil
            }
        } else {
            if pendingTargetClass != target {
                pendingTargetClass = target
                consecutiveBetter = 1
            } else {
                consecutiveBetter += 1
            }
            consecutiveWorse = 0

            if consecutiveBetter >= upgradeThreshold {
                let stepped = NetworkQualityClass(
                    rawValue: min(target.rawValue, currentClass.rawValue + 1)
                ) ?? target
                currentClass = stepped
                apply(profile: activeLadder[stepped.rawValue],
                      reason: "upgrade (target=\(target))")
                consecutiveBetter = 0
                pendingTargetClass = nil
            }
        }
    }

    private func reapplyCurrent() {
        apply(profile: activeLadder[currentClass.rawValue], reason: "reapply")
    }

    // MARK: Apply

    private func apply(profile: VideoStreamingProfile, reason: String) {
        guard let sender = videoSender else { return }

        // Order of precedence:
        //   1. Caller's explicit setMaxVideoBps (bitrateCeilingBps) — user wins.
        //   2. Device encode tier — never ask the chip for more than it handles.
        //   3. Thermal state — drop hard when serious/critical.
        //   4. Low-power mode — user explicitly asked to save battery.
        var effectiveBitrate = profile.maxBitrateBps
        var effectiveFps = profile.maxFramerate
        var effectiveScale = profile.scaleResolutionDownBy

        // (2a) Device tier bitrate ceiling.
        effectiveBitrate = min(effectiveBitrate, deviceTier.encodeBitrateCeilingBps)

        // (2b) Device tier resolution floor — but NOT for screen share.
        // iPad screen capture produces dimensions like 2048×2732. Dividing
        // those by anything other than 1.0 yields non-multiple-of-16 values
        // that crash the iOS H.264 hardware encoder. Screen share adapts via
        // fps + bitrate only; resolution stays at native.
        if contentType != .screenShare {
            effectiveScale = max(effectiveScale, deviceTier.minScaleResolutionDownBy)
        }

        // (3) Thermal pressure. For screen share, drop fps + bitrate harder
        // instead of scaling resolution (same crash reason as above).
        switch thermalState {
        case .nominal, .fair:
            break
        case .serious:
            effectiveBitrate = min(effectiveBitrate, contentType == .screenShare ? 1_500_000 : 800_000)
            effectiveFps = min(effectiveFps, contentType == .screenShare ? 10 : 20)
            if contentType != .screenShare {
                effectiveScale = max(effectiveScale, 2.0)
            }
        case .critical:
            effectiveBitrate = min(effectiveBitrate, contentType == .screenShare ? 600_000 : 400_000)
            effectiveFps = min(effectiveFps, contentType == .screenShare ? 6 : 12)
            if contentType != .screenShare {
                effectiveScale = max(effectiveScale, 3.0)
            }
        @unknown default:
            break
        }

        // (4) Low-power mode.
        if isLowPowerMode {
            effectiveBitrate = min(effectiveBitrate, contentType == .screenShare ? 1_000_000 : 600_000)
            effectiveFps = min(effectiveFps, contentType == .screenShare ? 10 : 20)
        }

        // (1) Caller's hard ceiling.
        if let ceiling = bitrateCeilingBps {
            effectiveBitrate = min(effectiveBitrate, ceiling)
        }

        let parameters = sender.parameters

        guard !parameters.encodings.isEmpty else {
            print("[AdaptiveStreamer] Skipping apply — sender has no encodings yet")
            return
        }

        for encoding in parameters.encodings {
            encoding.isActive = true
            encoding.maxBitrateBps = NSNumber(value: effectiveBitrate)
            encoding.maxFramerate = NSNumber(value: effectiveFps)
            // Always assign as NSNumber. For screen share this is always 1.0,
            // which the encoder treats as a no-op. For other content we use
            // the clamped value computed above.
            encoding.scaleResolutionDownBy = NSNumber(value: effectiveScale)
        }

        sender.parameters = parameters

        print("[AdaptiveStreamer] → \(profile.name)  bitrate=\(effectiveBitrate/1000)kbps fps=\(effectiveFps) scale=\(effectiveScale)x  reason=\(reason) tier=\(deviceTier) thermal=\(thermalState.rawValue) lowPower=\(isLowPowerMode) content=\(contentType)")
        currentProfile = profile
        DispatchQueue.main.async { [profile, callback = onProfileChange] in
            callback?(profile)
        }
    }
}
