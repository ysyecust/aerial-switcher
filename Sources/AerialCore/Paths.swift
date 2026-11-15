import Foundation

/// Locations of the macOS wallpaper files this app reads and writes.
/// Injectable so tests can point everything at a temporary directory.
public struct Paths: Sendable {
    public var manifest: URL
    public var store: URL
    public var videos: URL
    public var appSupport: URL

    public init(manifest: URL, store: URL, videos: URL, appSupport: URL) {
        self.manifest = manifest
        self.store = store
        self.videos = videos
        self.appSupport = appSupport
    }

    public static let bundledManifest = URL(
        fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json"
    )

    public init(home: URL, bundledManifest: URL? = nil) {
        let wallpaper = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
        let downloadedManifest = wallpaper.appendingPathComponent("aerials/manifest/entries.json")
        let manifest: URL
        if !FileManager.default.fileExists(atPath: downloadedManifest.path),
           let bundledManifest,
           FileManager.default.fileExists(atPath: bundledManifest.path) {
            manifest = bundledManifest
        } else {
            manifest = downloadedManifest
        }
        self.init(
            manifest: manifest,
            store: wallpaper.appendingPathComponent("Store/Index.plist"),
            videos: wallpaper.appendingPathComponent("aerials/videos"),
            appSupport: home.appendingPathComponent("Library/Application Support/AerialSwitcher")
        )
    }

    /// Re-evaluated on access so a downloaded manifest takes over from the bundled fallback
    /// once macOS fetches one.
    public static var live: Paths {
        Paths(home: FileManager.default.homeDirectoryForCurrentUser, bundledManifest: bundledManifest)
    }

    public var config: URL { appSupport.appendingPathComponent("config.json") }
    public var storeBackup: URL { appSupport.appendingPathComponent("Index.original.plist") }
    /// The Aerial this app last put on screen, to tell its own change from the user's.
    public var lastSet: URL { appSupport.appendingPathComponent("LastSet.txt") }
    /// Videos being downloaded, moved into `videos` once complete.
    public var partialDownloads: URL { appSupport.appendingPathComponent("Downloads") }
}

public struct AerialError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
