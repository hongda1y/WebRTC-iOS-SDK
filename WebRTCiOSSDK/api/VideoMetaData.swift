//
//  VideoMetaData.swift
//  WebRTCiOSSDK
//
//  Created by Socheat on 14/10/25.
//

import Foundation

public struct VideoMetaData: Codable {
    public var isMicMuted: Bool?
    public var isCameraOff: Bool?
    public var isScreenShare: Bool?
    public var userId: Int?
    public var username: String?
    public var profilePicture: String?
    public var role: String?
    public var entryId: Int?
    
    public init() {}
    
    public static func create(_ payload: [String : Any]) -> Self? {
        guard let metaDataString = payload["metaData"] as? String,
              let data = metaDataString.data(using: .utf8) else {
            return nil
        }
        
        return try? JSONDecoder().decode(VideoMetaData.self,
                                         from: data)
    }
}
