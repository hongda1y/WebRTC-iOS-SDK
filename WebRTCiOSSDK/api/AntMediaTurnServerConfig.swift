import Foundation
import WebRTC

public final class AntMediaTurnServerConfig {
    
    // MARK: - Shared Instance (Global)
    public static let shared = AntMediaTurnServerConfig()
    
    private init() {}
    
    // MARK: - Configurable Properties
    public var urls: [String] = []
    public var username: String = ""
    public var credential: String = ""
    
    // MARK: - Setup Method
    public func configure(
        urls: [String],
        username: String,
        credential: String
    ) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
    
    // MARK: - Build ICE Server
    public func iceServer() -> RTCIceServer {
        return RTCIceServer(
            urlStrings: urls,
            username: username,
            credential: credential
        )
    }
}
