//
//  VideoMetaData.swift
//  WebRTCiOSSDK
//
//  Created by Socheat on 14/10/25.
//

import Foundation

public struct VideoMetaData: Codable {
    var isMicMuted: Bool?
    var isCameraOff: Bool?
    var isScreenShare: Bool?
    var userId: Int?
    var username: String?
    var profilePicture: String?
    var role: String?
    var entryId: Int?
    
    static func create(_ payload: [String : Any]) -> Self? {
        guard let metaDataString = payload["metaData"] as? String,
              let data = metaDataString.data(using: .utf8) else {
            return nil
        }
        
        return try? JSONDecoder().decode(VideoMetaData.self,
                                         from: data)
    }
}
