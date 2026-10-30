import Foundation
import MediaPlayer

/// Exactly one framework owns system metadata. Older OSes and macOS retain the
/// established MediaPlayer route; iOS 27 uses the native session once configured.
@MainActor
enum NowPlayingMetadataSink {
    #if os(iOS)
    static var native: AnyObject?
    #endif
    static var info: [String: Any]? {
        get {
            #if os(iOS)
            if #available(iOS 27.0, *), let session = native as? LumaNativeMediaSession { return session.metadata }
            #endif
            return MPNowPlayingInfoCenter.default().nowPlayingInfo
        }
        set {
            #if os(iOS)
            if #available(iOS 27.0, *), let session = native as? LumaNativeMediaSession {
                session.apply(newValue)
                return
            }
            #endif
            MPNowPlayingInfoCenter.default().nowPlayingInfo = newValue
        }
    }
}
