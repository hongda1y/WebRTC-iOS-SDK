//
//  AntMediaError.swift
//  AntMediaSDK
//
//  Copyright © 2018 AntMedia. All rights reserved.
//

import Foundation

//public class AntMediaError {
//    
//    static func localized(_ message: String) -> String {
//        switch message {
//            case "no_stream_exist":
//                return "No stream exists on server."
//            case "unauthorized_access":
//                return "Unauthorized access: Check your token"
//            
//            default:
//                return "An error occured: " + message
//        }
//    }
//    
//}


public enum AntMediaError: Error, Equatable {
    
    // fixed cases
    case noStreamExist
    case unauthorizedAccess
    
    // dynamic case
    case custom(String)
    
    /// Failable initialiser that mirrors the auto-generated one.
    public init?(rawValue: String) {
        switch rawValue {
        case "no_stream_exist":     self = .noStreamExist
        case "unauthorized_access": self = .unauthorizedAccess
        default:
            if rawValue.hasPrefix("custom:") {
                let payload = String(rawValue.dropFirst("custom:".count))
                self = .custom(payload)
            } else {
                return nil
            }
        }
    }
    
    /// Human-readable message (same as your former `description`).
    public var description: String {
        switch self {
        case .noStreamExist:
            return "No stream exists on server."
        case .unauthorizedAccess:
            return "Unauthorized access: Check your token"
        case .custom(let msg):
            return msg
        }
    }
}
