import AerialCore
import AppKit
import Network
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    struct Download {
        var index: Int
        var count: Int
        var fraction: Double
        var totalBytes: Int64?
    }

    private enum FailureMessage: Equatable {
        case text(String)
        case one(String, String)
        case two(String, String, String)

        @MainActor var localized: String {
            switch self {
            case .text(let key): tr(key)
            case .one(let format, let arg): tr(format, tr(arg))
            case .two(let format, let first, let second): tr(format, first, tr(second))
            }
        }
    }

    private(set) var sets: [AerialSet] = []
    private(set) var config: Config
    private(set) var result: SyncResult?
    private(set) var download: Download?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var now = Date()

    /// Kept separate by source so a routine `sync()` only clears its own store error, rather
    /// than wiping a manifest, settings-save, login-item, or download failure.
    private var manifestError: FailureMessage?
    private var actionError: FailureMessage?
    private var syncError: FailureMessage?
    private var downloadError: FailureMessage?

    var error: String? {
        (manifestError ?? actionError ?? syncError ?? downloadError)?.localized
    }

    private let makePaths: () -> Paths
    private var paths: Paths { makePaths() }
    private var switcher: Switcher { Switcher(paths: paths, reload: reload) }
    private let reload: @Sendable () -> Void
    private let downloadVideo: (Aerial, @escaping @Sendable (Double) -> Void) async throws -> Void
    private let fetchDownloadSize: ([Aerial]) async -> Int64

    /// The phase last put on screen. The wallpaper is only touched again when the phase
    /// changes (or after waking), so picking another wallpaper by hand isn't undone a minute later.
    private var shownPhase: DayPhase?
    private var clockTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var downloadID = UUID()
    private var pathMonitor: NWPathMonitor?
    private var wasNetworkSatisfied = true

    init(
        paths: @escaping () -> Paths = { .live },
        reload: @escaping @Sendable () -> Void = WallpaperStore.reloadAgent,
        downloadVideo: ((Aerial, @escaping @Sendable (Double) -> Void) async throws -> Void)? = nil,
        fetchDownloadSize: (([Aerial]) async -> Int64)? = nil,
        startBackgroundTasks: Bool = true
    ) {
        self.makePaths = paths
        self.reload = reload
        self.downloadVideo = downloadVideo ?? { try await VideoLibrary(paths: paths()).download($0, progress: $1) }
        self.fetchDownloadSize = fetchDownloadSize ?? { await VideoLibrary(paths: paths()).downloadSize(of: $0) }
        config = Config.load(from: paths().config)
        loadSets()
        if startBackgroundTasks {
            startClock()
            observeSystemEvents()
        }
        sync(force: true)
        downloadMissing()
    }

    var selectedSet: AerialSet? { sets.first { $0.id == config.setID } }
    var schedule: Schedule? { selectedSet.map(config.schedule(for:)) }
    var currentPhase: DayPhase? { schedule?.phase(at: now) }
    var nextChange: (date: Date, phase: DayPhase)? { schedule?.nextChange(after: now) }

    var canRetryDownload: Bool {
        _ = result
        guard config.enabled, download == nil, let set = selectedSet else { return false }
        return !switcher.videos.missing(in: set).isEmpty
    }

    // MARK: - Actions

    func selectSet(_ id: String) {
        guard id != config.setID else { return }
        config.setID = id
        // Picking a set means wanting to see it.
        config.enabled = true
        config.paused = false
        cancelDownload()
        downloadError = nil
        save()
        downloadMissing()
    }

    /// While dragging, `commit` is false: the schedule on screen follows, but it's only saved,
    /// and the wallpaper only switched, once the drag ends.
    func setTime(_ time: TimeOfDay, for phase: DayPhase, commit: Bool = true) {
        guard let set = selectedSet else { return }
        var schedule = config.schedule(for: set)
        schedule.times[phase] = time
        config.schedules[set.id] = schedule
        if commit { save() }
    }

    func resetSchedule() {
        guard let set = selectedSet else { return }
        config.schedules[set.id] = nil
        save()
    }

    func setPaused(_ paused: Bool) {
        guard paused != config.paused else { return }
        config.paused = paused
        save()
        if !paused { downloadMissing() }
    }

    /// Turning off puts back the wallpaper from before the app took over; turning on again
    /// takes over again (keeping a fresh copy of whatever is showing then).
    func setEnabled(_ enabled: Bool) {
        guard enabled != config.enabled else { return }
        config.enabled = enabled
        // Pause keeps an Aerial on screen; off and back on there is none to keep.
        config.paused = false
        save()
        if enabled {
            downloadMissing()
            return
        }
        cancelDownload()
        downloadError = nil
        do {
            if try switcher.store.restoreBackup() { reload() }
        } catch {
            actionError = .text(error.localizedDescription)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        Localization.shared.language = language
        // The set names come from macOS, in the language asked for.
        loadSets()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            actionError = nil
        } catch {
            actionError = .one("Couldn't change Launch at Login: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Syncing

    private func save() {
        do {
            try config.save(to: paths.config)
            actionError = nil
        } catch {
            actionError = .one("Couldn't save settings: %@", error.localizedDescription)
        }
        sync(force: true)
    }

    func sync(force: Bool = false) {
        if sets.isEmpty {
            loadSets()
            if !sets.isEmpty { downloadMissing() }
        }
        now = Date()
        let phase = currentPhase
        guard force || phase != shownPhase else { return }
        do {
            result = try switcher.sync(set: selectedSet, config: config, at: now)
            syncError = nil
            switch result {
            case .switched, .alreadyShowing:
                shownPhase = phase
            case .notDownloaded:
                shownPhase = nil
                if downloadError == nil { downloadMissing() }
            default:
                shownPhase = nil
            }
        } catch {
            syncError = .text(error.localizedDescription)
            shownPhase = nil
        }
    }

    func loadSets() {
        do {
            sets = try Manifest.load(from: paths.manifest, preferredLanguages: Localization.shared.preferredLanguages)
            manifestError = nil
        } catch {
            manifestError = .text(error.localizedDescription)
        }
    }

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.sync()
            }
        }
    }

    private func observeSystemEvents() {
        let wakeEvents: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (center, name) in wakeEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sync(force: true)
                    self?.downloadMissing()
                }
            }
        }
        let clockEvents: [Notification.Name] = [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange]
        for name in clockEvents {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync(force: true) }
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isSatisfied = path.status == .satisfied
                let reconnected = !self.wasNetworkSatisfied && isSatisfied
                self.wasNetworkSatisfied = isSatisfied
                if reconnected { self.downloadMissing() }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    // MARK: - Downloads

    /// Downloads the chosen set's missing videos one by one, then switches.
    func downloadMissing() {
        guard config.enabled, !config.paused, downloadTask == nil, let set = selectedSet else { return }
        let missing = switcher.videos.missing(in: set)
        guard !missing.isEmpty else {
            downloadError = nil
            return
        }

        downloadError = nil
        let id = UUID()
        downloadID = id
        download = Download(index: 0, count: missing.count, fraction: 0)
        downloadTask = Task {
            let total = await fetchDownloadSize(missing)
            if downloadID == id { download?.totalBytes = total }

            var failure: FailureMessage?
            for (index, aerial) in missing.enumerated() {
                guard downloadID == id else { return }
                download?.index = index
                download?.fraction = 0
                do {
                    try await downloadVideo(aerial) { fraction in
                        Task { @MainActor in
                            guard self.downloadID == id else { return }
                            self.download?.fraction = fraction
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failure = .two("Downloading %1$@ failed: %2$@", aerial.label, error.localizedDescription)
                    break
                }
            }

            guard downloadID == id else { return }
            downloadTask = nil
            download = nil
            downloadError = failure
            sync(force: true)
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        download = nil
        downloadID = UUID()
    }
}
