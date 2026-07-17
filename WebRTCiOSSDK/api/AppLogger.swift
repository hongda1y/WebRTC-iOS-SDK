
import Foundation
import OSLog

class AppLogger {
    
    enum LogLevel {
        
        case info
        case error
        case warning
        case debug
        
        var type: OSLogType {
            switch self {
            case .info:
                return .info
            case .warning:
                return .error
            case .error:
                return .fault
            case .debug:
                return .debug
            }
        }
        
    }
    
    
    static let bundleID = "com.cmedcc.im"

    // MARK: - On-device file sink
    // Mirrors every log line to a file so they survive a debugger / network drop
    // (e.g. a wifi→4G switch that kills the wireless debug session). Retrieve via
    // Xcode → Devices & Simulators → app → ⚙ → Download Container, then open
    // AppData/Documents/antmedia-call.log.
    private static let fileQueue = DispatchQueue(label: "com.cmedcc.im.applogger.file")
    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static var logFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("antmedia-call.log")
    }

    /// Truncate the file and write a session header. Call when a call starts.
    static func startCallLog() {
#if DEBUG
        fileQueue.async {
            try? Data().write(to: logFileURL, options: .atomic)
            appendLine("==== call log started \(fileDateFormatter.string(from: Date())) ====")
        }
#endif
    }

    /// Append one raw line (timestamped) to the on-device log file.
    static func persist(_ message: String) {
#if DEBUG
        fileQueue.async { appendLine("\(fileDateFormatter.string(from: Date())) \(message)") }
#endif
    }

    private static func appendLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer {
                if #available(iOS 13.0, *) {
                try? handle.close()
                } else {
                    // Fallback on earlier versions
                }
            }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logFileURL, options: .atomic)   // first write creates the file
        }
    }

    static func log<T:CustomStringConvertible>(tag: String = "AntMedia-Logger",
                                               message: T,
                                               level: LogLevel = .info) {
#if DEBUG
        persist("[\(tag)] \(message)")
        if #available(iOS 14.0, *) {
            let logger = Logger(subsystem: bundleID,
                                category: tag)
            logger.log(level: level.type, "\(Date().toString()) \(message)")
        } else {
            print(tag,message)
        }
#endif

    }

}


extension Date {
    func toString(format: String = "yyyy-MM-dd hh:mm:ss") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: self)
    }
}
