import AppKit
import Combine
import Foundation

private struct ActiveRunJournal: Codable {
    var gameAppPath: String
    var resourcePath: String
    var backupDirectory: String
    var files: [ActiveRunFile]
}

private struct ActiveRunFile: Codable {
    var resourcePath: String
    var backupPath: String
    var hadOriginal: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings?
    @Published private(set) var instances: [ModInstance] = []
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var setupWindowsFolder: URL?
    @Published var setupGameApp: URL?
    @Published var manualPatchSelection: ManualPatchSelection?

    private var runTimer: Timer?
    private var launchedProcessID: pid_t?
    private var appTerminationObserver: NSObjectProtocol?
    private var isRestoringRun = false

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.instances, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppPaths.downloads, withIntermediateDirectories: true)
        Self.removeExpiredDownloads()
        settings = Self.loadSettings()
        setupGameApp = settings.map { URL(fileURLWithPath: $0.gameAppPath) } ?? GameAppLocator.defaultApp()
        loadInstances()
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let app,
                      let self,
                      self.launchedProcessID == app.processIdentifier else {
                    return
                }
                if !Self.gameIsRunning(at: URL(fileURLWithPath: self.settings?.gameAppPath ?? "")) {
                    self.restoreAfterGameExit()
                }
            }
        }
        recoverPreviousRunIfNeeded()
    }

    deinit {
        runTimer?.invalidate()
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
    }

    func completeSetup() {
        guard let windowsFolder = setupWindowsFolder, let gameApp = setupGameApp else {
            errorMessage = "Choose both the Windows game folder and the installed DELTARUNE app."
            return
        }
        let supportRoot = AppPaths.support
        isBusy = true
        statusMessage = "Backing up Windows chapter data..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resources = try GameAppLocator.resources(for: gameApp)
                let backup = supportRoot.appendingPathComponent("WindowsBackup", isDirectory: true)
                try WindowsBackup.backup(from: windowsFolder, to: backup)
                let settings = AppSettings(windowsBackupPath: backup.path, gameAppPath: gameApp.path)
                let data = try JSONEncoder.pretty.encode(settings)
                try data.write(to: AppPaths.settings, options: .atomic)
                DispatchQueue.main.async {
                    self.settings = settings
                    self.setupWindowsFolder = nil
                    self.statusMessage = "Setup complete. Windows chapter files are backed up."
                    self.isBusy = false
                    _ = resources
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func installArchive(_ archive: URL, deleteAfterSuccess: Bool = false) {
        guard let settings else {
            errorMessage = "Complete setup before installing a mod."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Reading and patching mod archive..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try DeltaModBuilder.build(
                    archive: archive,
                    windowsBackup: URL(fileURLWithPath: settings.windowsBackupPath),
                    supportRoot: AppPaths.support
                )
                let cleanupMessage = deleteAfterSuccess ? Self.removeDownloadedArchive(archive) : nil
                DispatchQueue.main.async {
                    self.instances.insert(result.instance, at: 0)
                    self.statusMessage = "Created instance: \(result.instance.name)" +
                        (cleanupMessage.map { " (\($0))" } ?? "")
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func analyzeManualArchive(_ archive: URL, modName: String, deleteAfterSuccess: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Finding xdelta patches..."
        Task {
            do {
                let options = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
                }.value
                manualPatchSelection = ManualPatchSelection(
                    archive: archive,
                    modName: modName,
                    options: options,
                    deleteAfterSuccess: deleteAfterSuccess
                )
                statusMessage = "Choose a chapter for each patch to include."
                isBusy = false
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func installManualArchive(_ selection: ManualPatchSelection, assignments: [ManualPatchAssignment]) {
        guard let settings else {
            errorMessage = "Complete setup before installing a manual patch."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        manualPatchSelection = nil
        statusMessage = "Applying selected patches..."
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.buildManual(
                        archive: selection.archive,
                        assignments: assignments,
                        modName: selection.modName,
                        windowsBackup: URL(fileURLWithPath: settings.windowsBackupPath),
                        supportRoot: AppPaths.support
                    )
                }.value
                let cleanupMessage = selection.deleteAfterSuccess
                    ? Self.removeDownloadedArchive(selection.archive)
                    : nil
                instances.insert(result.instance, at: 0)
                isBusy = false
                statusMessage = "Created instance: \(result.instance.name)" +
                    (cleanupMessage.map { " (\($0))" } ?? "")
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelManualPatchSelection() {
        guard let selection = manualPatchSelection else { return }
        manualPatchSelection = nil
        if selection.deleteAfterSuccess {
            if let cleanupMessage = Self.removeDownloadedArchive(selection.archive) {
                statusMessage = cleanupMessage
            } else {
                statusMessage = "Cancelled patch selection."
            }
        }
    }

    func downloadAndInstall(_ file: GameBananaFile, modName: String) {
        guard !isBusy else { return }
        guard file.isSelectableRelease else {
            errorMessage = "This release isn't a supported Deltamod, G3M ZIP, or manual patch."
            return
        }
        guard let settings else {
            errorMessage = "Complete setup before installing a mod."
            return
        }
        isBusy = true
        statusMessage = "Downloading \(file.name) from GameBanana..."
        Task {
            do {
                let archive = try await GameBananaCatalog.download(file)
                let kind = try DeltaModBuilder.archiveKind(archive)
                if kind == .other {
                    let options = try await Task.detached(priority: .userInitiated) {
                        try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
                    }.value
                    manualPatchSelection = ManualPatchSelection(
                        archive: archive,
                        modName: modName,
                        options: options,
                        deleteAfterSuccess: true
                    )
                    isBusy = false
                    statusMessage = "Choose a chapter for each patch to include."
                    return
                }

                let format = kind == .g3m || kind == .legacyG3M ? "G3M" : "Deltamod"
                statusMessage = "Preparing \(format) instance..."
                let result = try await Task.detached(priority: .userInitiated) {
                    return try DeltaModBuilder.build(
                        archive: archive,
                        windowsBackup: URL(fileURLWithPath: settings.windowsBackupPath),
                        supportRoot: AppPaths.support
                    )
                }.value
                let cleanupMessage = Self.removeDownloadedArchive(archive)
                instances.insert(result.instance, at: 0)
                isBusy = false
                statusMessage = "Created instance: \(result.instance.name)" +
                    (cleanupMessage.map { " (\($0))" } ?? "")
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = GameBananaError.message(for: error)
            }
        }
    }

    nonisolated private static func removeDownloadedArchive(_ archive: URL) -> String? {
        do {
            try FileManager.default.removeItem(at: archive)
            return nil
        } catch {
            return "Downloaded archive kept at \(archive.path): \(error.localizedDescription)"
        }
    }

    private static func removeExpiredDownloads() {
        let fileManager = FileManager.default
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: AppPaths.downloads,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let expirationDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            for entry in entries {
                let modified = try entry.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate ?? .distantFuture
                guard modified < expirationDate else { continue }
                do {
                    try fileManager.removeItem(at: entry)
                } catch {
                    NSLog("Could not remove expired mod download %@: %@", entry.path, error.localizedDescription)
                }
            }
        } catch {
            NSLog("Could not inspect mod downloads for cleanup: %@", error.localizedDescription)
        }
    }

    func launch(_ instance: ModInstance) {
        guard let settings else {
            errorMessage = "Complete setup before launching a mod."
            return
        }
        guard !isBusy else { return }
        let gameApp = URL(fileURLWithPath: settings.gameAppPath)
        guard !Self.gameIsRunning(at: gameApp) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        isBusy = true
        statusMessage = "Preparing a temporary modded launch..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.prepareRun(instance: instance, settings: settings)
                DispatchQueue.main.async {
                    self.openGame(at: gameApp)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func removeInstance(_ instance: ModInstance) {
        guard !isBusy else { return }
        do {
            try FileManager.default.removeItem(at: AppPaths.instanceDirectory(instance.id))
            instances.removeAll { $0.id == instance.id }
            statusMessage = "Removed \(instance.name)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func iconURL(for instance: ModInstance) -> URL? {
        guard let icon = instance.iconFile else { return nil }
        return AppPaths.instanceDirectory(instance.id).appendingPathComponent(icon)
    }

    func showCustomFilesInFinder(for instance: ModInstance) {
        let directory = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static var journalURL: URL {
        AppPaths.activeRun.appendingPathComponent("journal.json")
    }

    private static func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: AppPaths.settings) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    private func loadInstances() {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.instances,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        instances = directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else {
                return nil
            }
            return try? JSONDecoder().decode(ModInstance.self, from: data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func openGame(at gameApp: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: gameApp, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.restoreActiveRun(showStatus: false)
                    self.errorMessage = "Could not launch DELTARUNE: \(error.localizedDescription)"
                    self.isBusy = false
                    return
                }
                self.launchedProcessID = application?.processIdentifier
                self.isBusy = false
                self.statusMessage = "Mod active. The original game files will be restored when DELTARUNE closes."
                self.watchForGameExit(gameApp: gameApp)
            }
        }
    }

    private func watchForGameExit(gameApp: URL) {
        runTimer?.invalidate()
        let startedAt = Date()
        runTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(startedAt) >= 8 else { return }
                if !Self.gameIsRunning(at: gameApp) {
                    self.restoreAfterGameExit()
                }
            }
        }
    }

    private func restoreAfterGameExit() {
        runTimer?.invalidate()
        runTimer = nil
        launchedProcessID = nil
        restoreActiveRun(showStatus: true)
    }

    private func restoreActiveRun(showStatus: Bool) {
        let journalURL = Self.journalURL
        guard !isRestoringRun else { return }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            statusMessage = ""
            isBusy = false
            return
        }
        isRestoringRun = true
        isBusy = true
        statusMessage = "Restoring original game files..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.restoreRun(journalURL: journalURL)
                DispatchQueue.main.async {
                    self.isRestoringRun = false
                    self.statusMessage = showStatus ? "Original game files restored." : ""
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRestoringRun = false
                    self.errorMessage = "Could not restore the original game files: \(error.localizedDescription)"
                    self.statusMessage = "Recovery is still needed. Do not launch DELTARUNE until the files are restored."
                    self.isBusy = false
                }
            }
        }
    }

    private func recoverPreviousRunIfNeeded() {
        guard FileManager.default.fileExists(atPath: Self.journalURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.journalURL),
              let journal = try? JSONDecoder().decode(ActiveRunJournal.self, from: data) else {
            errorMessage = "A previous recovery record is damaged. The app cannot safely restore the game files; do not launch DELTARUNE."
            return
        }
        let gameApp = URL(fileURLWithPath: journal.gameAppPath)
        if Self.gameIsRunning(at: gameApp) {
            statusMessage = "A previous modded session is active. Original files will be restored after DELTARUNE closes."
            watchForGameExit(gameApp: gameApp)
        } else {
            restoreActiveRun(showStatus: true)
        }
    }

    nonisolated private static func prepareRun(instance: ModInstance, settings: AppSettings) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: Self.journalURL.path) else {
            throw ModManagerError.activeRun
        }
        if fileManager.fileExists(atPath: AppPaths.activeRun.path) {
            try fileManager.removeItem(at: AppPaths.activeRun)
        }
        let resources = try GameAppLocator.resources(for: URL(fileURLWithPath: settings.gameAppPath))
        let instanceDirectory = AppPaths.instanceDirectory(instance.id)
        let backupDirectory = AppPaths.activeRun.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var sourceByResource: [String: URL] = [:]
        for payload in instance.payloads {
            let resource = try SafePaths.relative(payload.resourcePath)
            let source = try SafePaths.url(
                for: "Payloads/\(payload.instanceFile)",
                under: instanceDirectory
            )
            guard fileManager.fileExists(atPath: source.path) else {
                throw ModManagerError.invalidArchive("An instance payload is missing: \(payload.instanceFile)")
            }
            sourceByResource[resource] = source
        }

        let customFilesDirectory = instanceDirectory.appendingPathComponent("CustomFiles", isDirectory: true)
        for (resource, source) in try ModCustomFiles.files(in: customFilesDirectory) {
            sourceByResource[resource] = source
        }

        var files: [ActiveRunFile] = []
        for resource in sourceByResource.keys.sorted() {
            let target = try SafePaths.url(for: resource, under: resources)
            try ensureNoSymlinkComponents(target, under: resources)
            if fileManager.fileExists(atPath: target.path) {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw ModManagerError.unsafePath(resource)
                }
            }
            let backupRelative = resource
            let backup = try SafePaths.url(for: backupRelative, under: backupDirectory)
            let existed = fileManager.fileExists(atPath: target.path)
            if existed {
                try fileManager.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: target, to: backup)
            }
            files.append(ActiveRunFile(
                resourcePath: resource,
                backupPath: backupRelative,
                hadOriginal: existed
            ))
        }

        let journal = ActiveRunJournal(
            gameAppPath: settings.gameAppPath,
            resourcePath: resources.path,
            backupDirectory: backupDirectory.path,
            files: files
        )
        try fileManager.createDirectory(at: AppPaths.activeRun, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(journal).write(to: Self.journalURL, options: .atomic)

        do {
            for file in files {
                guard let source = sourceByResource[file.resourcePath] else {
                    throw ModManagerError.invalidArchive("An instance payload is missing: \(file.resourcePath)")
                }
                let target = try SafePaths.url(for: file.resourcePath, under: resources)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = target.deletingLastPathComponent()
                    .appendingPathComponent(".dmt-\(UUID().uuidString)")
                try fileManager.copyItem(at: source, to: temporary)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: temporary, to: target)
            }
        } catch {
            do {
                try restoreRun(journalURL: Self.journalURL)
            } catch {
                throw ModManagerError.launchRollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    nonisolated private static func restoreRun(journalURL: URL) throws {
        let data = try Data(contentsOf: journalURL)
        let journal = try JSONDecoder().decode(ActiveRunJournal.self, from: data)
        let resources = URL(fileURLWithPath: journal.resourcePath)
        let backups = URL(fileURLWithPath: journal.backupDirectory)
        let fileManager = FileManager.default

        for file in journal.files {
            let target = try SafePaths.url(for: file.resourcePath, under: resources)
            try ensureNoSymlinkComponents(target, under: resources)
            if file.hadOriginal {
                let backup = try SafePaths.url(for: file.backupPath, under: backups)
                guard fileManager.fileExists(atPath: backup.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: backup.path])
                }
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = target.deletingLastPathComponent()
                    .appendingPathComponent(".dmt-restore-\(UUID().uuidString)")
                try fileManager.copyItem(at: backup, to: temporary)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: temporary, to: target)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
        try fileManager.removeItem(at: AppPaths.activeRun)
    }

    nonisolated private static func ensureNoSymlinkComponents(_ target: URL, under root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            throw ModManagerError.unsafePath(targetPath)
        }
        let relative = String(targetPath.dropFirst(rootPath.count + 1))
        var cursor = root.standardizedFileURL
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw ModManagerError.unsafePath(cursor.path)
                }
            }
        }
    }

    private static func gameIsRunning(at gameApp: URL) -> Bool {
        let expected = gameApp.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == expected
        }
    }
}
