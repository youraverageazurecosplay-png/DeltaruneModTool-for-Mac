import AppKit
import Combine
import Foundation

private struct ActiveRunJournal: Codable {
    var gameAppPath: String
    var resourcePath: String
    var backupDirectory: String
    var files: [ActiveRunFile]
    var game: ModGame? = nil
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
    @Published var isCheckingForUpdates = false
    @Published private(set) var availableModUpdates: [String: GameBananaFile] = [:]
    @Published private(set) var isCheckingModUpdates = false

    private var runTimer: Timer?
    private var launchedProcessID: pid_t?
    private var appTerminationObserver: NSObjectProtocol?
    private var isRestoringRun = false
    private var launchedGame: ModGame = .deltarune

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
                let game = self.launchedGame
                if !Self.gameIsRunning(at: self.gameAppURL(for: game), game: game) {
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
                let settings = AppSettings(
                    windowsBackupPath: backup.path,
                    gameAppPath: gameApp.path,
                    windowsSourcePath: windowsFolder.path
                )
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

    func updateGameApp(to gameApp: URL) {
        guard !isBusy else { return }
        guard let current = settings else {
            errorMessage = "Complete setup before changing the game app."
            return
        }
        guard !Self.gameIsRunning(at: URL(fileURLWithPath: current.gameAppPath)) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }
        do {
            _ = try GameAppLocator.resources(for: gameApp)
            var updated = current
            updated.gameAppPath = gameApp.path
            try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
            settings = updated
            setupGameApp = gameApp
            statusMessage = "Updated Mac game app location."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateWindowsBackup(from windowsFolder: URL) {
        guard !isBusy else { return }
        guard let current = settings else {
            errorMessage = "Complete setup before changing the Windows backup."
            return
        }
        guard !Self.gameIsRunning(at: URL(fileURLWithPath: current.gameAppPath)) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        let supportRoot = AppPaths.support
        let newBackup = supportRoot.appendingPathComponent(
            "WindowsBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        isBusy = true
        statusMessage = "Backing up Windows chapter data..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try WindowsBackup.backup(from: windowsFolder, to: newBackup)
                var updated = current
                updated.windowsBackupPath = newBackup.path
                updated.windowsSourcePath = windowsFolder.path
                try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
                DispatchQueue.main.async {
                    self.settings = updated
                    self.statusMessage = "Windows game files backed up."
                    self.isBusy = false
                    Self.removePreviousWindowsBackup(at: URL(fileURLWithPath: current.windowsBackupPath))
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: newBackup.path) {
                        try FileManager.default.removeItem(at: newBackup)
                    }
                } catch {
                    NSLog("Could not remove incomplete Windows backup %@: %@", newBackup.path, error.localizedDescription)
                }
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func showWindowsBackupInFinder() {
        guard let settings else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: settings.windowsBackupPath, isDirectory: true)
        ])
    }

    func configureUndertale(app: URL, folder: URL) {
        guard !isBusy else { return }
        guard let current = settings else {
            errorMessage = "Complete DELTARUNE setup before configuring Undertale."
            return
        }
        guard app.pathExtension.lowercased() == "app",
              (try? GameAppLocator.undertaleResources(for: app)) != nil else {
            errorMessage = "Choose the Steam-installed Undertale.app containing Contents/Resources/game.ios."
            return
        }
        guard !Self.gameIsRunning(at: app, game: .undertale) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        let backup = AppPaths.support.appendingPathComponent(
            "UndertaleBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        isBusy = true
        statusMessage = "Backing up the Windows Undertale data.win source..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try UndertaleBackup.backup(from: folder, to: backup)
                var updated = current
                updated.undertaleAppPath = app.path
                updated.undertaleGameFolderPath = folder.path
                updated.undertaleBackupPath = backup.path
                try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
                DispatchQueue.main.async {
                    self.settings = updated
                    self.statusMessage = "Windows Undertale data.win source backed up."
                    self.isBusy = false
                    if let previous = current.undertaleBackupPath {
                        Self.removeManagedBackup(at: URL(fileURLWithPath: previous), prefix: "UndertaleBackup")
                    }
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: backup.path) {
                        try FileManager.default.removeItem(at: backup)
                    }
                } catch {
                    NSLog("Could not remove incomplete Undertale backup %@: %@", backup.path, error.localizedDescription)
                }
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                    self.isBusy = false
                }
            }
        }
    }

    func updateUndertaleApp(to app: URL) {
        guard !isBusy else { return }
        guard app.pathExtension.lowercased() == "app",
              (try? GameAppLocator.undertaleResources(for: app)) != nil else {
            errorMessage = "Choose the Steam-installed Undertale.app containing Contents/Resources/game.ios."
            return
        }
        guard var updated = settings else {
            errorMessage = "Complete DELTARUNE setup before configuring Undertale."
            return
        }
        guard !Self.gameIsRunning(
            at: URL(fileURLWithPath: updated.undertaleAppPath ?? app.path),
            game: .undertale
        ) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }
        updated.undertaleAppPath = app.path
        do {
            try JSONEncoder.pretty.encode(updated).write(to: AppPaths.settings, options: .atomic)
            settings = updated
            statusMessage = "Updated Undertale Mac game app."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isConfigured(for game: ModGame) -> Bool {
        guard let settings else { return false }
        switch game {
        case .deltarune:
            return true
        case .undertale:
            guard let app = settings.undertaleAppPath,
                  let folder = settings.undertaleGameFolderPath,
                  let backup = settings.undertaleBackupPath else {
                return false
            }
            return (try? GameAppLocator.undertaleResources(for: URL(fileURLWithPath: app))) != nil &&
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: folder).appendingPathComponent("data.win").path) &&
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: backup).appendingPathComponent("data.win").path)
        }
    }

    private func backupPath(for game: ModGame, settings: AppSettings) -> String? {
        switch game {
        case .deltarune:
            settings.windowsBackupPath
        case .undertale:
            settings.undertaleBackupPath
        }
    }

    private func gameAppURL(for game: ModGame) -> URL {
        let path: String
        switch game {
        case .deltarune:
            path = settings?.gameAppPath ?? ""
        case .undertale:
            path = settings?.undertaleAppPath ?? ""
        }
        return URL(fileURLWithPath: path)
    }

    func checkForUpdates() {
        guard !isBusy, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        statusMessage = "Checking for updates..."
        Task {
            defer { isCheckingForUpdates = false }
            do {
                let release = try await AppUpdateService.latestRelease()
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.3"
                if AppUpdateService.isNewer(release.tagName, than: currentVersion) {
                    statusMessage = "Version \(release.tagName) is available. Opening the release download page..."
                    guard NSWorkspace.shared.open(release.htmlURL) else {
                        throw AppUpdateError.badResponse
                    }
                } else {
                    statusMessage = "You're up to date (version \(currentVersion))."
                }
            } catch {
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func checkForModUpdates(catalog: GameBananaCatalog) {
        guard !isCheckingModUpdates, !isBusy else { return }
        isCheckingModUpdates = true
        availableModUpdates = [:]
        Task {
            defer { isCheckingModUpdates = false }
            var failure: String?
            for instance in instances {
                guard let modID = instance.gameBananaModID,
                      let installedFileID = instance.gameBananaFileID else {
                    continue
                }
                do {
                    let details = try await catalog.details(forModID: modID)
                    let latest = details.files
                        .filter(\.isSupportedRelease)
                        .sorted { ($0.dateAdded ?? 0) > ($1.dateAdded ?? 0) }
                        .first
                    guard let latest,
                          latest.id != installedFileID,
                          instance.gameBananaFileDateAdded == nil ||
                            (latest.dateAdded ?? 0) > (instance.gameBananaFileDateAdded ?? 0) else {
                        continue
                    }
                    availableModUpdates[instance.id] = latest
                } catch {
                    failure = "Couldn't check for updates to \(instance.name): \(GameBananaError.message(for: error))"
                }
            }
            if let failure {
                errorMessage = failure
            }
        }
    }

    func updateMod(_ instance: ModInstance, using file: GameBananaFile, catalog: GameBananaCatalog) {
        guard !isBusy else { return }
        guard let current = instances.first(where: { $0.id == instance.id }),
              let modID = current.gameBananaModID,
              let settings,
              let backupPath = backupPath(for: current.targetGame, settings: settings) else {
            errorMessage = "This mod update is no longer available or its game backup is missing."
            return
        }
        isBusy = true
        statusMessage = "Updating \(current.name)..."
        Task {
            do {
                let updated = try await buildAndReplaceInstance(
                    current,
                    modID: modID,
                    file: file,
                    backupPath: backupPath,
                    catalog: catalog
                )
                if let index = instances.firstIndex(where: { $0.id == updated.id }) {
                    instances[index] = updated
                }
                availableModUpdates.removeValue(forKey: updated.id)
                isBusy = false
                statusMessage = "Updated \(updated.name) to \(file.releaseTitle)."
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = "Couldn't update \(current.name): \(error.localizedDescription)"
            }
        }
    }

    func updateAllMods(catalog: GameBananaCatalog) {
        guard !isBusy else { return }
        let pending = instances.compactMap { instance -> (ModInstance, GameBananaFile)? in
            guard let file = availableModUpdates[instance.id] else { return nil }
            return (instance, file)
        }
        guard !pending.isEmpty else { return }
        guard let settings else {
            errorMessage = "Complete setup before updating mods."
            return
        }
        isBusy = true
        Task {
            var updatedCount = 0
            var failures: [String] = []
            for (instance, file) in pending {
                guard let modID = instance.gameBananaModID,
                      let backupPath = backupPath(for: instance.targetGame, settings: settings) else {
                    failures.append("\(instance.name): missing GameBanana source or backup.")
                    continue
                }
                statusMessage = "Updating \(instance.name)..."
                do {
                    let updated = try await buildAndReplaceInstance(
                        instance,
                        modID: modID,
                        file: file,
                        backupPath: backupPath,
                        catalog: catalog
                    )
                    if let index = instances.firstIndex(where: { $0.id == updated.id }) {
                        instances[index] = updated
                    }
                    availableModUpdates.removeValue(forKey: updated.id)
                    updatedCount += 1
                } catch {
                    failures.append("\(instance.name): \(error.localizedDescription)")
                }
            }
            isBusy = false
            if failures.isEmpty {
                statusMessage = "Updated \(updatedCount) mod\(updatedCount == 1 ? "" : "s")."
            } else {
                statusMessage = "Updated \(updatedCount) mod\(updatedCount == 1 ? "" : "s"); some updates failed."
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }

    private func buildAndReplaceInstance(
        _ instance: ModInstance,
        modID: Int,
        file: GameBananaFile,
        backupPath: String,
        catalog: GameBananaCatalog
    ) async throws -> ModInstance {
        let details = try await catalog.details(forModID: modID)
        let archive = try await GameBananaCatalog.download(file)
        defer {
            if let warning = Self.removeDownloadedArchive(archive) {
                NSLog("GameBanana update download cleanup failed: %@", warning)
            }
        }
        let kind = try await Task.detached(priority: .userInitiated) {
            try DeltaModBuilder.archiveKind(archive)
        }.value
        let result: ModBuildResult
        if instance.targetGame == .deltarune, kind != .other {
            result = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.build(
                    archive: archive,
                    windowsBackup: URL(fileURLWithPath: backupPath),
                    supportRoot: AppPaths.support
                )
            }.value
        } else {
            let options = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
            }.value
            let assignments = try Self.updateAssignments(for: options, instance: instance)
            result = try await Task.detached(priority: .userInitiated) {
                try DeltaModBuilder.buildManual(
                    archive: archive,
                    assignments: assignments,
                    modName: details.name,
                    windowsBackup: URL(fileURLWithPath: backupPath),
                    supportRoot: AppPaths.support,
                    game: instance.targetGame
                )
            }.value
        }
        var updated = result.instance
        updated.id = instance.id
        updated.name = instance.name
        updated.game = instance.targetGame
        updated.gameBananaModID = modID
        updated.gameBananaFileID = file.id
        updated.gameBananaFileDateAdded = file.dateAdded
        updated = await addingGameBananaIconIfNeeded(
            to: ModBuildResult(instance: updated, directory: result.directory),
            from: details.imageURL
        ).instance
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Self.replaceUpdatedInstance(
                    instance,
                    with: ModBuildResult(instance: updated, directory: result.directory)
                )
            }.value
        } catch {
            if FileManager.default.fileExists(atPath: result.directory.path) {
                do {
                    try FileManager.default.removeItem(at: result.directory)
                } catch {
                    NSLog("Could not remove failed update build %@: %@", result.directory.path, error.localizedDescription)
                }
            }
            throw error
        }
    }

    nonisolated private static func updateAssignments(
        for options: [ManualPatchOption],
        instance: ModInstance
    ) throws -> [ManualPatchAssignment] {
        guard !options.isEmpty else { throw ModManagerError.missingManualPatch }
        var assignments: [ManualPatchAssignment] = []
        for option in options {
            let target: ManualPatchTarget?
            if instance.targetGame == .undertale {
                target = options.count == 1 && option.kind != .dylib ? .undertale : nil
            } else if option.suggestsLauncher {
                target = .launcher
            } else if let chapter = option.suggestedChapter {
                target = .chapter(chapter)
            } else {
                let dataTargets = instance.payloads.compactMap { payload -> ManualPatchTarget? in
                    if payload.resourcePath == "game.ios" { return .launcher }
                    guard let match = payload.resourcePath.range(
                        of: #"^chapter([1-5])_mac/game\.ios$"#,
                        options: .regularExpression
                    ) else { return nil }
                    let chapterText = payload.resourcePath[match]
                        .dropFirst("chapter".count)
                        .prefix(1)
                    return Int(chapterText).map(ManualPatchTarget.chapter)
                }
                target = dataTargets.count == 1 ? dataTargets[0] : nil
            }
            guard let target, option.kind != .dylib else {
                throw ModManagerError.unsupportedPatch(
                    "The update release doesn't identify a safe game-data target for \(option.path)."
                )
            }
            assignments.append(ManualPatchAssignment(
                patchPath: option.path,
                target: target,
                kind: option.kind
            ))
        }
        return assignments
    }

    nonisolated private static func replaceUpdatedInstance(
        _ current: ModInstance,
        with build: ModBuildResult
    ) throws -> ModInstance {
        let fileManager = FileManager.default
        let oldDirectory = AppPaths.instanceDirectory(current.id)
        let customRoot = oldDirectory.appendingPathComponent("CustomFiles", isDirectory: true)
        let customFiles = try ModCustomFiles.files(in: customRoot)
        for (relativePath, source) in customFiles {
            let destination = try SafePaths.url(
                for: "CustomFiles/\(relativePath)",
                under: build.directory
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }
        if build.instance.iconFile == nil, let oldIcon = current.iconFile {
            let source = try SafePaths.url(for: oldIcon, under: oldDirectory)
            let destination = build.directory.appendingPathComponent(oldIcon)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
        try JSONEncoder.pretty.encode(build.instance)
            .write(to: build.directory.appendingPathComponent("manifest.json"), options: .atomic)

        let backupDirectory = AppPaths.instances.appendingPathComponent(
            ".UpdateBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: oldDirectory, to: backupDirectory)
        do {
            try fileManager.moveItem(at: build.directory, to: oldDirectory)
        } catch {
            do {
                try fileManager.moveItem(at: backupDirectory, to: oldDirectory)
            } catch {
                throw ModManagerError.launchRollbackFailed(
                    "The update failed and the previous instance could not be restored: \(error.localizedDescription)"
                )
            }
            throw error
        }
        do {
            try fileManager.removeItem(at: backupDirectory)
        } catch {
            NSLog("Could not remove prior instance backup %@: %@", backupDirectory.path, error.localizedDescription)
        }
        return build.instance
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

    func analyzeManualArchive(
        _ archive: URL,
        modName: String,
        deleteAfterSuccess: Bool = false,
        game: ModGame = .deltarune
    ) {
        guard !isBusy else { return }
        guard isConfigured(for: game) else {
            errorMessage = "Configure \(game.title) in Settings before installing a mod."
            return
        }
        isBusy = true
        statusMessage = "Finding xdelta patches..."
        Task {
            do {
                let options = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
                }.value
                if installSingleUndertaleXdeltaIfPossible(
                    options,
                    archive: archive,
                    game: game,
                    modName: modName,
                    deleteAfterSuccess: deleteAfterSuccess
                ) {
                    return
                }
                manualPatchSelection = ManualPatchSelection(
                    archive: archive,
                    modName: modName,
                    options: options,
                    deleteAfterSuccess: deleteAfterSuccess,
                    game: game,
                    updatingInstanceID: nil
                )
                statusMessage = game == .undertale
                    ? "Choose which Undertale files to include."
                    : "Choose a chapter for each patch to include."
                isBusy = false
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func installManualArchive(_ selection: ManualPatchSelection, assignments: [ManualPatchAssignment]) {
        installManualArchive(selection, assignments: assignments, modName: selection.modName)
    }

    func inspectManualArchive(_ archive: URL, game: ModGame = .deltarune) async throws -> ManualPatchSelection {
        let options = try await Task.detached(priority: .userInitiated) {
            try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
        }.value
        return ManualPatchSelection(
            archive: archive,
            modName: archive.deletingPathExtension().lastPathComponent,
            options: options,
            deleteAfterSuccess: false,
            game: game
        )
    }

    func installManualArchive(
        _ selection: ManualPatchSelection,
        assignments: [ManualPatchAssignment],
        modName: String
    ) {
        guard let settings else {
            errorMessage = "Complete setup before installing a manual patch."
            return
        }
        guard isConfigured(for: selection.game),
              let backupPath = backupPath(for: selection.game, settings: settings) else {
            errorMessage = "Configure \(selection.game.title) in Settings before installing a mod."
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
                        modName: modName,
                        windowsBackup: URL(fileURLWithPath: backupPath),
                        supportRoot: AppPaths.support,
                        game: selection.game
                    )
                }.value
                let (installedInstance, iconWarning) = await addingGameBananaIconIfNeeded(
                    to: result,
                    from: selection.gameBananaIconURL
                )
                var installed = installedInstance
                installed.gameBananaModID = selection.gameBananaModID
                installed.gameBananaFileID = selection.gameBananaFileID
                installed.gameBananaFileDateAdded = selection.gameBananaFileDateAdded
                try JSONEncoder.pretty.encode(installed)
                    .write(to: result.directory.appendingPathComponent("manifest.json"), options: .atomic)
                let cleanupMessage = selection.deleteAfterSuccess
                    ? Self.removeDownloadedArchive(selection.archive)
                    : nil
                if let updatingID = selection.updatingInstanceID,
                   let existing = instances.first(where: { $0.id == updatingID }) {
                    let updated = try Self.replaceUpdatedInstance(
                        existing,
                        with: ModBuildResult(instance: installed, directory: result.directory)
                    )
                    guard let index = instances.firstIndex(where: { $0.id == updatingID }) else {
                        throw ModManagerError.invalidArchive("The mod instance being updated was removed.")
                    }
                    instances[index] = updated
                } else {
                    instances.insert(installed, at: 0)
                }
                isBusy = false
                statusMessage = (selection.updatingInstanceID == nil ? "Created instance: " : "Updated instance: ") +
                    installed.name +
                    (iconWarning.map { " (\($0))" } ?? "") +
                    (cleanupMessage.map { " (\($0))" } ?? "")
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    private func installSingleUndertaleXdeltaIfPossible(
        _ options: [ManualPatchOption],
        archive: URL,
        game: ModGame,
        modName: String,
        deleteAfterSuccess: Bool,
        gameBananaIconURL: URL? = nil,
        gameBananaModID: Int? = nil,
        gameBananaFileID: Int? = nil,
        gameBananaFileDateAdded: Int64? = nil
    ) -> Bool {
        guard game == .undertale,
              options.count == 1,
              options[0].kind == .xdelta else {
            return false
        }
        let selection = ManualPatchSelection(
            archive: archive,
            modName: modName,
            options: options,
            deleteAfterSuccess: deleteAfterSuccess,
            gameBananaIconURL: gameBananaIconURL,
            game: .undertale,
            gameBananaModID: gameBananaModID,
            gameBananaFileID: gameBananaFileID,
            gameBananaFileDateAdded: gameBananaFileDateAdded
        )
        isBusy = false
        installManualArchive(
            selection,
            assignments: [
                ManualPatchAssignment(
                    patchPath: options[0].path,
                    target: .undertale,
                    kind: .xdelta
                )
            ],
            modName: modName
        )
        return true
    }

    func addManualArchive(
        _ selection: ManualPatchSelection,
        assignments: [ManualPatchAssignment],
        named modName: String,
        to instance: ModInstance
    ) {
        guard let settings else {
            errorMessage = "Complete setup before editing a mod instance."
            return
        }
        guard let backupPath = backupPath(for: instance.targetGame, settings: settings) else {
            errorMessage = "The backup for \(instance.targetGame.title) is not configured."
            return
        }
        guard !isBusy else { return }
        let cleanName = modName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Enter a name for these files."
            return
        }
        isBusy = true
        statusMessage = "Adding files to \(instance.name)..."
        Task {
            var result: ModBuildResult?
            do {
                let built = try await Task.detached(priority: .userInitiated) {
                    try DeltaModBuilder.buildManual(
                        archive: selection.archive,
                        assignments: assignments,
                        modName: cleanName,
                        windowsBackup: URL(fileURLWithPath: backupPath),
                        supportRoot: AppPaths.support,
                        game: instance.targetGame
                    )
                }.value
                result = built
                let updated = try await Task.detached(priority: .userInitiated) {
                    try ModInstancePayloadMerger.merge(
                        built,
                        into: AppPaths.instanceDirectory(instance.id)
                    )
                }.value
                if let index = instances.firstIndex(where: { $0.id == instance.id }) {
                    instances[index] = updated
                }
                statusMessage = "Added \(cleanName) to \(instance.name)."
                isBusy = false
                do {
                    try FileManager.default.removeItem(at: built.directory)
                } catch {
                    errorMessage = "Files were added, but temporary files could not be removed: \(error.localizedDescription)"
                }
            } catch {
                if let result {
                    try? FileManager.default.removeItem(at: result.directory)
                }
                isBusy = false
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func replaceSkippedFile(_ skippedFile: ModSkippedFile, with dylibURL: URL, in instance: ModInstance) {
        guard !isBusy else { return }
        guard let current = instances.first(where: { $0.id == instance.id }) else {
            errorMessage = "This mod instance is no longer available."
            return
        }
        isBusy = true
        statusMessage = "Repatching \(current.name) with \(dylibURL.lastPathComponent)..."
        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try ModInstancePayloadMerger.replaceSkippedFile(
                        skippedFile,
                        with: dylibURL,
                        in: AppPaths.instanceDirectory(current.id)
                    )
                }.value
                if let index = instances.firstIndex(where: { $0.id == current.id }) {
                    instances[index] = updated
                }
                isBusy = false
                statusMessage = "Repatched \(current.name). The Mac replacement will be applied the next time you launch this instance."
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

    func handleOneClickInstall(_ url: URL, catalog: GameBananaCatalog) {
        guard GameBananaOneClickLink.usesSupportedScheme(url) else { return }
        guard !isBusy else {
            errorMessage = "Wait for the current mod operation to finish before using a one-click install."
            return
        }
        guard settings != nil else {
            errorMessage = "Complete setup and select your own game files before installing a mod."
            return
        }
        guard let link = GameBananaOneClickLink(url: url) else {
            errorMessage = "This GameBanana one-click link is invalid or uses an unsupported install type."
            return
        }

        isBusy = true
        statusMessage = "Finding the selected GameBanana release..."
        Task {
            do {
                let details = try await catalog.details(forModID: link.modID)
                guard let file = details.files.first(where: { $0.id == link.fileID }) else {
                    throw GameBananaError.oneClickReleaseNotFound
                }
                guard file.isSelectableRelease else {
                    throw GameBananaError.unsupportedDownload
                }
                isBusy = false
                downloadAndInstall(
                    file,
                    modName: details.name,
                    gameBananaIconURL: details.imageURL,
                    game: catalog.game,
                    gameBananaModID: link.modID
                )
            } catch {
                isBusy = false
                statusMessage = ""
                errorMessage = GameBananaError.message(for: error)
            }
        }
    }

    func downloadAndInstall(
        _ file: GameBananaFile,
        modName: String,
        gameBananaIconURL: URL? = nil,
        game: ModGame = .deltarune,
        gameBananaModID: Int? = nil
    ) {
        guard !isBusy else { return }
        guard file.isSelectableRelease else {
            errorMessage = "This release isn't a supported Deltamod, G3M ZIP, or manual patch."
            return
        }
        guard let settings else {
            errorMessage = "Complete setup before installing a mod."
            return
        }
        guard isConfigured(for: game),
              backupPath(for: game, settings: settings) != nil else {
            errorMessage = "Configure \(game.title) in Settings before installing a mod."
            return
        }
        isBusy = true
        statusMessage = "Downloading \(file.name) from GameBanana..."
        Task {
            do {
                let archive = try await GameBananaCatalog.download(file)
                let kind = try DeltaModBuilder.archiveKind(archive)
                if kind == .other || game == .undertale {
                    let options = try await Task.detached(priority: .userInitiated) {
                        try DeltaModBuilder.manualPatchOptions(archive: archive, supportRoot: AppPaths.support)
                    }.value
                    if game == .undertale,
                       installSingleUndertaleXdeltaIfPossible(
                            options,
                            archive: archive,
                            game: game,
                            modName: modName,
                            deleteAfterSuccess: true,
                            gameBananaIconURL: gameBananaIconURL,
                            gameBananaModID: gameBananaModID,
                            gameBananaFileID: file.id,
                            gameBananaFileDateAdded: file.dateAdded
                       ) {
                        return
                    }
                    manualPatchSelection = ManualPatchSelection(
                        archive: archive,
                        modName: modName,
                        options: options,
                        deleteAfterSuccess: true,
                        gameBananaIconURL: gameBananaIconURL,
                        game: game,
                        gameBananaModID: gameBananaModID,
                        gameBananaFileID: file.id,
                        gameBananaFileDateAdded: file.dateAdded
                    )
                    isBusy = false
                    statusMessage = game == .undertale
                        ? "Choose the Undertale data.win file to patch."
                        : "Choose a chapter for each patch to include."
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
                var installed = result.instance
                installed.game = game
                installed.gameBananaModID = gameBananaModID
                installed.gameBananaFileID = file.id
                installed.gameBananaFileDateAdded = file.dateAdded
                try JSONEncoder.pretty.encode(installed)
                    .write(to: result.directory.appendingPathComponent("manifest.json"), options: .atomic)
                let cleanupMessage = Self.removeDownloadedArchive(archive)
                instances.insert(installed, at: 0)
                isBusy = false
                statusMessage = "Created instance: \(installed.name)" +
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

    private func addingGameBananaIconIfNeeded(
        to build: ModBuildResult,
        from imageURL: URL?
    ) async -> (instance: ModInstance, warning: String?) {
        guard build.instance.iconFile == nil, let imageURL else {
            return (build.instance, nil)
        }
        do {
            let data = try await GameBananaCatalog.downloadImageData(from: imageURL)
            guard NSImage(data: data) != nil else {
                throw GameBananaError.badResponse
            }
            let pathExtension = ["png", "jpg", "jpeg"].contains(imageURL.pathExtension.lowercased())
                ? imageURL.pathExtension.lowercased()
                : "png"
            let filename = "gamebanana-icon.\(pathExtension)"
            let iconURL = build.directory.appendingPathComponent(filename)
            try data.write(to: iconURL, options: .atomic)

            var updated = build.instance
            updated.iconFile = filename
            do {
                try JSONEncoder.pretty.encode(updated)
                    .write(to: build.directory.appendingPathComponent("manifest.json"), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: iconURL)
                throw error
            }
            return (updated, nil)
        } catch {
            let warning = "GameBanana icon wasn't downloaded: \(error.localizedDescription)"
            NSLog("%@", warning)
            return (build.instance, warning)
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
        let game = instance.targetGame
        guard isConfigured(for: game) else {
            errorMessage = "Configure \(game.title) in Settings before launching."
            return
        }
        let gameApp = gameAppURL(for: game)
        guard !Self.gameIsRunning(at: gameApp, game: game) else {
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
                    self.openGame(at: gameApp, game: game)
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

    func launchVanilla(for game: ModGame = .deltarune) {
        guard settings != nil else {
            errorMessage = "Complete setup before launching \(game.title)."
            return
        }
        guard !isBusy else { return }
        guard isConfigured(for: game) else {
            errorMessage = "Configure \(game.title) in Settings before launching."
            return
        }
        let gameApp = gameAppURL(for: game)
        guard !Self.gameIsRunning(at: gameApp, game: game) else {
            errorMessage = ModManagerError.gameAlreadyRunning.localizedDescription
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.journalURL.path) else {
            errorMessage = ModManagerError.activeRun.localizedDescription
            return
        }

        isBusy = true
        statusMessage = "Launching vanilla \(game.title)..."
        openGame(at: gameApp, game: game)
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

    func files(for instance: ModInstance) -> [ModInstanceFileEntry] {
        var files: [String: ModInstanceFileEntry] = [:]
        for payload in instance.payloads {
            files[payload.resourcePath] = ModInstanceFileEntry(
                path: payload.resourcePath,
                sourceLabel: payload.sourceLabel ?? "Installed mod"
            )
        }
        let customRoot = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles", isDirectory: true)
        do {
            for path in try ModCustomFiles.files(in: customRoot).keys {
                files[path] = ModInstanceFileEntry(path: path, sourceLabel: "Custom files")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return files.values.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    func renameInstance(_ instance: ModInstance, to name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "A mod instance name cannot be empty."
            return
        }
        guard let current = instances.first(where: { $0.id == instance.id }) else {
            errorMessage = "This mod instance is no longer available."
            return
        }
        var updated = current
        updated.name = cleanName
        do {
            try JSONEncoder.pretty.encode(updated)
                .write(to: AppPaths.instanceDirectory(instance.id).appendingPathComponent("manifest.json"), options: .atomic)
            if let index = instances.firstIndex(where: { $0.id == instance.id }) {
                instances[index] = updated
            }
            statusMessage = "Saved changes to \(cleanName)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showCustomFilesInFinder(for instance: ModInstance) {
        let directory = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles", isDirectory: true)
        do {
            guard let settings else {
                errorMessage = "Complete setup before opening custom files."
                return
            }
            let resources = try Self.resourcesURL(for: instance.targetGame, settings: settings)
            try ModCustomFiles.prepareMirroredDirectories(from: resources, at: directory)
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func showCustomMusicInFinder(for instance: ModInstance) {
        let directory = AppPaths.instanceDirectory(instance.id)
            .appendingPathComponent("CustomFiles/mus", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static var journalURL: URL {
        AppPaths.activeRun.appendingPathComponent("journal.json")
    }

    nonisolated private static func resourcesURL(for game: ModGame, settings: AppSettings) throws -> URL {
        switch game {
        case .deltarune:
            return try GameAppLocator.resources(for: URL(fileURLWithPath: settings.gameAppPath))
        case .undertale:
            guard let path = settings.undertaleAppPath else {
                throw ModManagerError.invalidGameApp
            }
            return try GameAppLocator.undertaleResources(for: URL(fileURLWithPath: path))
        }
    }

    nonisolated private static func gameAppPath(for game: ModGame, settings: AppSettings) throws -> String {
        switch game {
        case .deltarune:
            return settings.gameAppPath
        case .undertale:
            guard let path = settings.undertaleAppPath else {
                throw ModManagerError.invalidGameApp
            }
            return path
        }
    }

    private static func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: AppPaths.settings) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    nonisolated private static func removePreviousWindowsBackup(at backup: URL) {
        removeManagedBackup(at: backup, prefix: "WindowsBackup")
    }

    nonisolated private static func removeManagedBackup(at backup: URL, prefix: String) {
        let support = AppPaths.support.standardizedFileURL
        let standardizedBackup = backup.standardizedFileURL
        let isManagedBackup = standardizedBackup.lastPathComponent == prefix ||
            standardizedBackup.lastPathComponent.hasPrefix("\(prefix)-")
        guard standardizedBackup.deletingLastPathComponent() == support, isManagedBackup else {
            return
        }
        do {
            if FileManager.default.fileExists(atPath: standardizedBackup.path) {
                try FileManager.default.removeItem(at: standardizedBackup)
            }
        } catch {
            NSLog("Could not remove previous Windows backup %@: %@", standardizedBackup.path, error.localizedDescription)
        }
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

    private func openGame(at gameApp: URL, game: ModGame) {
        launchedGame = game
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: gameApp, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.restoreActiveRun(showStatus: false)
                    self.errorMessage = "Could not launch \(game.title): \(error.localizedDescription)"
                    self.isBusy = false
                    return
                }
                self.launchedProcessID = application?.processIdentifier
                self.isBusy = false
                self.statusMessage = FileManager.default.fileExists(atPath: Self.journalURL.path)
                    ? "Mod active. Original game files will be restored when \(game.title) closes."
                    : "Vanilla \(game.title) is running."
                self.watchForGameExit(gameApp: gameApp, game: game)
            }
        }
    }

    private func watchForGameExit(gameApp: URL, game: ModGame) {
        runTimer?.invalidate()
        let startedAt = Date()
        runTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(startedAt) >= 8 else { return }
                if !Self.gameIsRunning(at: gameApp, game: game) {
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
        let game = journal.game ?? .deltarune
        launchedGame = game
        if Self.gameIsRunning(at: gameApp, game: game) {
            statusMessage = "A previous modded session is active. Original files will be restored after \(game.title) closes."
            watchForGameExit(gameApp: gameApp, game: game)
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
        let resources = try resourcesURL(for: instance.targetGame, settings: settings)
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
            gameAppPath: try gameAppPath(for: instance.targetGame, settings: settings),
            resourcePath: resources.path,
            backupDirectory: backupDirectory.path,
            files: files,
            game: instance.targetGame
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

    private static func gameIsRunning(at gameApp: URL, game: ModGame = .deltarune) -> Bool {
        let expected = gameApp.standardizedFileURL.path
        let appIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == expected
        }
        return appIsRunning || (game == .undertale && undertaleProcessIsRunning())
    }

    nonisolated private static func undertaleProcessIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-if", "undertale"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("Could not check whether Undertale is running: %@", error.localizedDescription)
            return true
        }
    }
}
