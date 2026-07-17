//
//  DeviceCapabilityTier.swift
//  WebRTCiOSSDK
//
//  Created by Hong Daly on 27/04/2026.
//


//
//  DeviceCapabilityProfile.swift
//
//  Classifies the current device into an encode-capability tier. Used by
//  AdaptiveVideoStreamer to cap the upper end of the bitrate ladder so we
//  never ask the encoder to do something it'll thermal-throttle on.
//

import Foundation
import UIKit

enum DeviceCapabilityTier: Int, Comparable {
    case low      // A10 / A11 era, older iPads — 540p30 ceiling
    case mid      // A12 / A13 era — 720p30 comfortable
    case high     // A14+ / M-series — 1080p30 comfortable

    static func < (lhs: DeviceCapabilityTier, rhs: DeviceCapabilityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Hard cap on `maxBitrateBps` for any profile applied on this device.
    /// Beyond this, the encoder spends CPU and battery to produce bits the
    /// network probably can't ship anyway, and triggers thermal throttling
    /// which CAUSES the lag we're trying to avoid.
    var encodeBitrateCeilingBps: Int {
        switch self {
        case .low:  return 1_200_000
        case .mid:  return 2_200_000
        case .high: return 4_000_000
        }
    }

    /// Cap on `scaleResolutionDownBy = 1.0` — i.e. native capture. If the
    /// capturer is producing 1080p but this device is .low, we force at
    /// least a 1.5× downscale even on the "excellent" profile.
    var minScaleResolutionDownBy: Double {
        switch self {
        case .low:  return 1.5
        case .mid:  return 1.0
        case .high: return 1.0
        }
    }
}

enum DeviceCapability {

    /// Best-effort classification. Uses `hw.machine` model identifier on
    /// device, falls back conservatively in the simulator. We don't try
    /// to enumerate every model — we group by SoC generation since that's
    /// what actually drives encode performance.
    static let current: DeviceCapabilityTier = classifyCurrent()

    private static func classifyCurrent() -> DeviceCapabilityTier {

        #if targetEnvironment(simulator)
        // Simulator runs on the host Mac — assume high. (You usually don't
        // want to ship a simulator-only build, but this keeps dev sane.)
        return .high
        #else

        let model = hardwareModelIdentifier()

        // ---- iPhones ----
        // iPhone 12 (A14) and later → high
        if let _ = model.range(of: #"^iPhone1[3-9],"#, options: .regularExpression)
            ?? model.range(of: #"^iPhone[2-9][0-9],"#, options: .regularExpression) {
            return .high
        }
        // iPhone XS / XR / 11 / SE2 / SE3 (A12, A13, A15) → mid-to-high; lump as mid
        if model.hasPrefix("iPhone11,") || model.hasPrefix("iPhone12,") {
            return .mid
        }
        // iPhone X / 8 / 8 Plus (A11) and earlier → low
        if model.hasPrefix("iPhone10,") || model.hasPrefix("iPhone9,")
            || model.hasPrefix("iPhone8,") || model.hasPrefix("iPhone7,") {
            return .low
        }

        // ---- iPads ----
        // iPad Pro (M-series) and recent → high. M1 = "iPad13,8" onward; M2,M4 higher.
        if let _ = model.range(of: #"^iPad1[3-9],"#, options: .regularExpression)
            ?? model.range(of: #"^iPad[2-9][0-9],"#, options: .regularExpression) {
            return .high
        }
        // iPad Air 3 / iPad 7-9 / iPad mini 5-6 → mid
        if model.hasPrefix("iPad11,") || model.hasPrefix("iPad12,") {
            return .mid
        }
        // Older iPads → low
        if model.hasPrefix("iPad") {
            return .low
        }

        // Unknown future device — default to mid (safer than guessing high
        // and having a brand-new low-end variant overheat).
        return .mid
        #endif
    }

    private static func hardwareModelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.compactMap { element -> String? in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(bitPattern: value)))
        }.joined()
        return id
    }
}

extension DeviceCapabilityTier {
    func encodeBitrateCeilingBps(for contentType: StreamContentType) -> Int {
        let base: Int
        switch self {
        case .low:  base = 1_200_000
        case .mid:  base = 2_200_000
        case .high: base = 4_000_000
        }
        // Screen share needs much higher headroom — text legibility scales
        // with bitrate far more than camera content does.
        if contentType == .screenShare {
            return base * 2
        }
        return base
    }
}
