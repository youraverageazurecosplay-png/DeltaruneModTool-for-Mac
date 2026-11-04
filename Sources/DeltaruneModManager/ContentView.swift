import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct DeltaruneModManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 700)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var catalog = GameBananaCatalog()
    @State private var section: MainSection = .discover
    @State private var selectedMod: GameBananaMod?
    @State private var editingInstance: ModInstance?
    @State private var instanceSearchText = ""
    @State private var windowsFolder: URL?
    @State private var gameApp: URL?

    var body: some View {
        Group {
            if model.settings == nil {
                SetupView(model: model, windowsFolder: $windowsFolder, gameApp: $gameApp)
            } else {
                dashboard
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background {
            GeometryReader { geometry in
                ZStack {
                    Color(red: 0.045, green: 0.065, blue: 0.13)
                    if let image = titleBackground {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .overlay(Color(red: 0.015, green: 0.025, blue: 0.075).opacity(0.70))
                    }
                }
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if gameApp == nil {
                gameApp = model.setupGameApp
            }
        }
        .onOpenURL { url in
            model.handleOneClickInstall(url, catalog: catalog)
        }
        .onChange(of: section) { newSection in
            if newSection == .instances {
                model.checkForModUpdates(catalog: catalog)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $selectedMod) { mod in
            GameBananaModDetailSheet(mod: mod, catalog: catalog) { file in
                model.downloadAndInstall(
                    file,
                    modName: mod.name,
                    gameBananaIconURL: mod.imageURL,
                    game: .deltarune,
                    gameBananaModID: mod.id
                )
            }
        }
        .sheet(item: $model.manualPatchSelection) { selection in
            ManualPatchAssignmentSheet(selection: selection, actionTitle: "Create Instance") { assignments, name in
                model.installManualArchive(selection, assignments: assignments, modName: name)
            } cancel: {
                model.cancelManualPatchSelection()
            }
        }
        .sheet(item: $editingInstance) { instance in
            InstanceEditorSheet(instance: instance, model: model)
        }
    }

    private var titleBackground: NSImage? {
        guard let url = Bundle.main.url(forResource: "title-background", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var filteredInstances: [ModInstance] {
        let query = instanceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentGameInstances = model.instances.filter { $0.targetGame == .deltarune }
        guard !query.isEmpty else { return currentGameInstances }
        return currentGameInstances.filter { instance in
            ([instance.name, instance.version, instance.description] + instance.authors)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 0) {
                            Text("DELT")
                                .tracking(2)
                            Text("A")
                                .tracking(2)
                                .overlay {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundStyle(.red)
                                        .offset(y: 1)
                                }
                            Text("RUNE")
                                .tracking(2)
                        }
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .fixedSize()
                        HStack(spacing: 8) {
                            Text("MOD MANAGER")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(3)
                                .foregroundStyle(.cyan)
                            Text("made by toast")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Button {
                            model.checkForUpdates()
                        } label: {
                            if model.isCheckingForUpdates {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 20)
                            } else {
                                Label("Update", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || model.isCheckingForUpdates)
                        .help("Check for a newer version and open its installer download page.")
                        .fixedSize()

                        Button {
                            model.launchVanilla(for: .deltarune)
                        } label: {
                            Label("Launch Vanilla", systemImage: "gamecontroller")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                        .help("Launch DELTARUNE without applying a mod instance.")
                        .fixedSize()

                        Button {
                            chooseModArchive()
                        } label: {
                            Label("Install Mod", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(model.isBusy)
                        .fixedSize()
                    }
                }

                HStack(spacing: 8) {
                    sectionButton(.discover, title: "Discover", icon: "sparkle.magnifyingglass")
                    sectionButton(.instances, title: "My Mods", icon: "square.stack.3d.up")
                    sectionButton(.settings, title: "Settings", icon: "gearshape")
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            if !model.statusMessage.isEmpty {
                HStack(spacing: 10) {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(model.statusMessage)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(.white.opacity(0.035))
            }

            if section == .discover {
                ModCatalogView(catalog: catalog, select: { selectedMod = $0 })
            } else if section == .settings {
                settingsPage
            } else if filteredInstances.isEmpty && instanceSearchText.isEmpty {
                installedEmptyState
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.55))
                        TextField("Search your mods", text: $instanceSearchText)
                            .textFieldStyle(.plain)
                        if !instanceSearchText.isEmpty {
                            Button {
                                instanceSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    .padding(11)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                    if filteredInstances.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.45))
                            Text("No matching mods")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Try a different name, version, description, or author.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .trailing, spacing: 14) {
                                if !model.availableModUpdates.isEmpty {
                                    Button {
                                        model.updateAllMods(catalog: catalog)
                                    } label: {
                                        Label(
                                            "Update All (\(model.availableModUpdates.count))",
                                            systemImage: "arrow.triangle.2.circlepath"
                                        )
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.indigo)
                                    .disabled(model.isBusy || model.isCheckingModUpdates)
                                }
                                if model.isCheckingModUpdates {
                                    ProgressView("Checking for mod updates…")
                                        .font(.system(size: 11))
                                }
                                LazyVStack(spacing: 14) {
                                ForEach(filteredInstances) { instance in
                                    InstanceCard(
                                        instance: instance,
                                        iconURL: model.iconURL(for: instance),
                                        launch: { model.launch(instance) },
                                        update: model.availableModUpdates[instance.id].map { file in
                                            { model.updateMod(instance, using: file, catalog: catalog) }
                                        },
                                        showCustomFiles: { model.showCustomFilesInFinder(for: instance) },
                                        showCustomMusic: { model.showCustomMusicInFinder(for: instance) },
                                        replaceSkippedFile: { skippedFile in
                                            chooseDylibReplacement(skippedFile, for: instance)
                                        },
                                        edit: { editingInstance = instance },
                                        remove: { model.removeInstance(instance) },
                                        disabled: model.isBusy
                                    )
                                }
                                }
                            }
                            .padding(24)
                        }
                    }
                }
            }

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            HStack {
                Label("Original game files are restored after each session", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text("Windows backup + Mac install configured")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 13)
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text("Manage the game locations used for mod installation and launch.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))

            SetupPathRow(
                number: "01",
                title: "Mac DELTARUNE.app",
                detail: "Select the installed Mac game app.",
                path: model.settings?.gameAppPath,
                buttonTitle: "Change App",
                action: chooseGameAppForSettings
            )
            SetupPathRow(
                number: "02",
                title: "Windows game source",
                detail: "Choose the folder containing chapterN_windows/data.win.",
                path: model.settings?.windowsSourcePath ?? "Original source path not saved",
                buttonTitle: "Choose & Back Up",
                action: chooseWindowsBackupSource
            )
            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current Windows backup")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.settings?.windowsBackupPath ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    model.showWindowsBackupInFinder()
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            }
            .padding(15)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            Text("Changing the Windows source creates a fresh backup for future installs. Existing mod instances keep their current patched files.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    }

    private var installedEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 42))
                .foregroundStyle(.cyan.opacity(0.8))
            Text("No mod instances yet")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Browse the GameBanana catalog and choose a Deltamod release, or import an archive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.58))
                .font(.system(size: 14))
                .lineSpacing(5)
            HStack(spacing: 12) {
                Button("Discover Mods") { section = .discover }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                Button("Choose Mod Archive") { chooseModArchive() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionButton(_ item: MainSection, title: String, icon: String) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(section == item ? .white : .white.opacity(0.75))
            .background {
                if section == item {
                    RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.11))
                }
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func chooseModArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GameBanana mod archive"
        panel.message = "Deltamod and G3M packages install automatically. Manual patches are analyzed before chapter assignment."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "deltamod" || ext == "zip" || ext == "xdelta" else {
            model.errorMessage = "Choose a .deltamod, ZIP, or xdelta patch."
            return
        }
        do {
            if try DeltaModBuilder.archiveKind(url) != .other {
                model.installArchive(url)
            } else {
                model.analyzeManualArchive(
                    url,
                    modName: url.deletingPathExtension().lastPathComponent,
                    game: .deltarune
                )
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func chooseDylibReplacement(_ skippedFile: ModSkippedFile, for instance: ModInstance) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Mac replacement for \(skippedFile.targetPath)"
        panel.message = "Choose a compatible macOS .dylib. It will be installed as \(skippedFile.macReplacementPath) when this mod instance launches."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.replaceSkippedFile(skippedFile, with: url, in: instance)
    }

    private func chooseGameAppForSettings() {
        let panel = NSOpenPanel()
        panel.title = "Select Mac DELTARUNE.app"
        panel.message = "Choose the installed Mac game app used for modded and vanilla launches."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateGameApp(to: url)
    }

    private func chooseWindowsBackupSource() {
        let panel = NSOpenPanel()
        panel.title = "Select Windows DELTARUNE folder"
        panel.message = "Choose the folder containing chapterN_windows/data.win files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateWindowsBackup(from: url)
    }

}

private enum MainSection {
    case discover
    case instances
    case settings
}

struct ManualPatchAssignmentSheet: View {
    let selection: ManualPatchSelection
    let actionTitle: String
    let install: ([ManualPatchAssignment], String) -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTargets: [String: ManualPatchTarget]
    @State private var modName: String

    init(
        selection: ManualPatchSelection,
        actionTitle: String,
        install: @escaping ([ManualPatchAssignment], String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.selection = selection
        self.actionTitle = actionTitle
        self.install = install
        self.cancel = cancel
        _modName = State(initialValue: selection.modName)

        var defaults: [String: ManualPatchTarget] = [:]
        var usedTargets = Set<ManualPatchTarget>()
        for option in selection.options {
            let target: ManualPatchTarget?
            if option.suggestsLauncher {
                target = .launcher
            } else {
                target = option.suggestedChapter.map(ManualPatchTarget.chapter)
            }
            guard let target else { continue }
            if option.kind != .dylib, !usedTargets.insert(target).inserted { continue }
            defaults[option.id] = target
        }
        _selectedTargets = State(initialValue: defaults)
    }

    private var assignments: [ManualPatchAssignment] {
        selection.options.compactMap { option in
            guard let target = selectedTargets[option.id] else { return nil }
            return ManualPatchAssignment(
                patchPath: option.path,
                target: target,
                kind: option.kind
            )
        }
    }

    private func targetIsUsed(_ target: ManualPatchTarget, by option: ManualPatchOption) -> Bool {
        option.kind != .dylib && selection.options.contains {
            $0.id != option.id && $0.kind != .dylib && selectedTargets[$0.id] == target
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assign files to game targets")
                        .font(.system(size: 18, weight: .bold))
                    Text(selection.archive.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    cancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Found \(selection.options.count) installable file\(selection.options.count == 1 ? "" : "s"). Chapter and launcher names are selected automatically; you can change any selection. Launcher patches use the backed-up Windows root data.win and target the Mac app's root game.ios. Chapter files target their matching game file; dylibs are copied into the selected chapter folder. Leave files set to Skip if you don't want them installed.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.67))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $modName)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(selection.options) { option in
                        HStack(spacing: 12) {
                            Image(systemName: iconName(for: option.kind))
                                .foregroundStyle(option.kind == .dataWin ? .orange : option.kind == .dylib ? .purple : .cyan)
                            Text(option.path)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Picker("Target", selection: Binding(
                                get: { selectedTargets[option.id] },
                                set: { target in
                                    if let target {
                                        selectedTargets[option.id] = target
                                    } else {
                                        selectedTargets.removeValue(forKey: option.id)
                                    }
                                }
                            )) {
                                Text("Skip").tag(nil as ManualPatchTarget?)
                                if option.kind != .dylib {
                                    Text("Launcher").tag(ManualPatchTarget.launcher as ManualPatchTarget?)
                                        .disabled(targetIsUsed(.launcher, by: option))
                                    ForEach(1...5, id: \.self) { chapter in
                                        Text("Chapter \(chapter)")
                                            .tag(ManualPatchTarget.chapter(chapter) as ManualPatchTarget?)
                                            .disabled(targetIsUsed(.chapter(chapter), by: option))
                                    }
                                }
                            }
                            .frame(width: 155)
                        }
                        .padding(10)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 340)

            HStack {
                Text("\(assignments.count) file\(assignments.count == 1 ? "" : "s") selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button(actionTitle) {
                    install(assignments, modName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(assignments.isEmpty || modName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 720, height: 540)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func iconName(for kind: ManualPatchOption.Kind) -> String {
        switch kind {
        case .xdelta: "doc.zipper"
        case .dataWin: "externaldrive"
        case .dylib: "shippingbox"
        }
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel
    @Binding var windowsFolder: URL?
    @Binding var gameApp: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DELTARUNE")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(3)
                    Text("MOD MANAGER SETUP")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30))
                    .foregroundStyle(.cyan.opacity(0.8))
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            VStack(alignment: .leading, spacing: 20) {
                Text("One-time setup")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Install DELTARUNE, then select your local Windows chapter files and Mac game app. This manager uses the game files you provide and does not download or include them.")
                    .foregroundStyle(.white.opacity(0.68))
                    .font(.system(size: 14))
                    .lineSpacing(4)

                SetupPathRow(
                    number: "01",
                    title: "Windows DELTARUNE folder",
                    detail: "Must contain chapter1_windows/data.win, chapter2_windows/data.win, etc.",
                    path: windowsFolder?.path,
                    buttonTitle: "Choose Windows Folder",
                    action: chooseWindowsFolder
                )
                SetupPathRow(
                    number: "02",
                    title: "Mac DELTARUNE.app",
                    detail: "Steam's installed Mac game. We'll look in its Contents/Resources folder.",
                    path: gameApp?.path,
                    buttonTitle: "Choose Mac App",
                    action: chooseGameApp
                )

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.cyan)
                    Text("Select the Windows folder containing chapterN_windows/data.win files and the installed Mac app below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.68))
                    Spacer(minLength: 4)
                    Link(
                        "Open DELTARUNE on Steam",
                        destination: URL(string: "https://store.steampowered.com/app/1671210/DELTARUNE/")!
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

                HStack {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(model.statusMessage).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Back Up Files & Continue") {
                        model.setupWindowsFolder = windowsFolder
                        model.setupGameApp = gameApp
                        model.completeSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(model.isBusy || windowsFolder == nil || gameApp == nil)
                }
            }
            .padding(30)
            .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func chooseWindowsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Windows DELTARUNE folder"
        panel.message = "Choose the folder containing chapterN_windows/data.win files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            windowsFolder = panel.url
        }
    }

    private func chooseGameApp() {
        let panel = NSOpenPanel()
        panel.title = "Select Mac DELTARUNE.app"
        panel.message = "Choose the DELTARUNE app installed by Steam."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            gameApp = panel.url
        }
    }
}

private struct SetupPathRow: View {
    var number: String
    var title: String
    var detail: String
    var path: String?
    var buttonTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 32, height: 32)
                .background(.cyan.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(path ?? detail)
                    .font(.system(size: 11, design: path == nil ? .default : .monospaced))
                    .foregroundStyle(path == nil ? .white.opacity(0.48) : .green.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(buttonTitle, action: action).buttonStyle(.bordered)
        }
        .padding(15)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct InstanceCard: View {
    let instance: ModInstance
    let iconURL: URL?
    let launch: () -> Void
    let update: (() -> Void)?
    let showCustomFiles: () -> Void
    let showCustomMusic: () -> Void
    let replaceSkippedFile: (ModSkippedFile) -> Void
    let edit: () -> Void
    let remove: () -> Void
    let disabled: Bool
    @State private var confirmRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 17) {
            icon
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(instance.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if !instance.version.isEmpty {
                        Text(instance.version)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }
                }

                Text(instance.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                Text("\(instance.payloads.count) Mac file\(instance.payloads.count == 1 ? "" : "s") in this instance")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                if !instance.warnings.isEmpty {
                    DisclosureGroup("Compatibility notes (\(instance.warnings.count))") {
                        ForEach(instance.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(instance.skippedFiles ?? []) { skippedFile in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Windows-only file: \(skippedFile.targetPath)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.orange.opacity(0.9))
                                    Text("Choose a Mac .dylib to replace it at \(skippedFile.macReplacementPath).")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.58))
                                }
                                Spacer(minLength: 4)
                                Button("Repatch with .dylib…") {
                                    replaceSkippedFile(skippedFile)
                                }
                                .buttonStyle(.bordered)
                                .disabled(disabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .font(.system(size: 11))
                    .tint(.orange)
                }
            }
            Spacer(minLength: 10)
            VStack(spacing: 9) {
                Button(action: edit) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .frame(minWidth: 86)
                }
                .buttonStyle(.bordered)
                .disabled(disabled)
                Button(action: launch) {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 86)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(disabled)
                if let update {
                    Button(action: update) {
                        Label("Update Mod", systemImage: "arrow.triangle.2.circlepath")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(disabled)
                }
                Button(action: showCustomFiles) {
                    Label("Show in Finder", systemImage: "folder")
                        .frame(minWidth: 112)
                }
                .buttonStyle(.bordered)
                .help("Open the empty folder tree matching Contents/Resources. Add a file at its matching path (for example chapter3_mac/helper.dylib); it is applied only while this mod runs.")
                .disabled(disabled)
                if instance.targetGame == .deltarune {
                    Button(action: showCustomMusic) {
                        Label("Music Folder", systemImage: "music.note")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.bordered)
                    .help("Open this mod's CustomFiles/mus folder for custom songs.")
                    .disabled(disabled)
                }
                Button("Remove") { confirmRemoval = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.46))
                    .disabled(disabled)
            }
        }

        .padding(17)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
        .confirmationDialog("Remove \(instance.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Instance", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved mod instance. The original game files are unaffected.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.indigo.opacity(0.2))
                Image(systemName: "sparkles")
                    .font(.system(size: 25))
                    .foregroundStyle(.cyan)
            }
        }
    }
}
