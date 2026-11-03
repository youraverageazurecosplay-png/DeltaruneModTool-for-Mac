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
        .background(Color(red: 0.045, green: 0.065, blue: 0.13))
        .preferredColorScheme(.dark)
        .onAppear {
            if gameApp == nil {
                gameApp = model.setupGameApp
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
                model.downloadAndInstall(file, modName: mod.name)
            }
        }
        .sheet(item: $model.manualPatchSelection) { selection in
            ManualPatchAssignmentSheet(selection: selection) { assignments in
                model.installManualArchive(selection, assignments: assignments)
            } cancel: {
                model.cancelManualPatchSelection()
            }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DELTARUNE")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(3)
                    Text("MOD MANAGER")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(.cyan)
                }
                Spacer()
                HStack(spacing: 4) {
                    sectionButton(.discover, title: "Discover", icon: "sparkle.magnifyingglass")
                    sectionButton(.instances, title: "My Mods", icon: "square.stack.3d.up")
                }
                Button {
                    chooseModArchive()
                } label: {
                    Label("Install Mod", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

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
            } else if model.instances.isEmpty {
                installedEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.instances) { instance in
                            InstanceCard(
                                instance: instance,
                                iconURL: model.iconURL(for: instance),
                                launch: { model.launch(instance) },
                                showCustomFiles: { model.showCustomFilesInFinder(for: instance) },
                                remove: { model.removeInstance(instance) },
                                disabled: model.isBusy
                            )
                        }
                    }
                    .padding(24)
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
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(section == item ? .white : .white.opacity(0.55))
                .background {
                    if section == item {
                        RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.11))
                    }
                }
        }
        .buttonStyle(.plain)
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
                    modName: url.deletingPathExtension().lastPathComponent
                )
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private enum MainSection {
    case discover
    case instances
}

private struct ManualPatchAssignmentSheet: View {
    let selection: ManualPatchSelection
    let install: ([ManualPatchAssignment]) -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedChapters: [String: Int]

    init(
        selection: ManualPatchSelection,
        install: @escaping ([ManualPatchAssignment]) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.selection = selection
        self.install = install
        self.cancel = cancel

        var defaults: [String: Int] = [:]
        var usedChapters = Set<Int>()
        for option in selection.options {
            guard let chapter = option.suggestedChapter,
                  usedChapters.insert(chapter).inserted else {
                defaults[option.id] = 0
                continue
            }
            defaults[option.id] = chapter
        }
        _selectedChapters = State(initialValue: defaults)
    }

    private var assignments: [ManualPatchAssignment] {
        selection.options.compactMap { option in
            guard let chapter = selectedChapters[option.id], chapter > 0 else { return nil }
            return ManualPatchAssignment(patchPath: option.path, chapter: chapter)
        }
    }

    private func chapterIsUsed(_ chapter: Int, by option: ManualPatchOption) -> Bool {
        selection.options.contains {
            $0.id != option.id && selectedChapters[$0.id] == chapter
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assign patches to chapters")
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
            Text("Found \(selection.options.count) xdelta patch\(selection.options.count == 1 ? "" : "es"). Chapter numbers in patch names are selected automatically; you can change any selection. Leave patches set to Skip if you don't want them installed. Included lang_*.json files are applied to each selected chapter.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.67))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(selection.options) { option in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.zipper")
                                .foregroundStyle(.cyan)
                            Text(option.path)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Picker("Chapter", selection: Binding(
                                get: { selectedChapters[option.id] ?? 0 },
                                set: { selectedChapters[option.id] = $0 }
                            )) {
                                Text("Skip").tag(0)
                                ForEach(1...5, id: \.self) { chapter in
                                    Text("Chapter \(chapter)")
                                        .tag(chapter)
                                        .disabled(chapterIsUsed(chapter, by: option))
                                }
                            }
                            .frame(width: 145)
                        }
                        .padding(10)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 340)

            HStack {
                Text("\(assignments.count) patch\(assignments.count == 1 ? "" : "es") selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button("Patch & Create Instance") {
                    install(assignments)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(assignments.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 650, height: 510)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
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
                Text("Install DELTARUNE through Steam, then select your local Windows chapter files and Mac game app. Steam handles ownership and game downloads; this manager does not download or include game files.")
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
                    Text("Steam verifies ownership and installs the official game. Select the Windows folder containing chapterN_windows/data.win and the installed Mac app below.")
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
    let showCustomFiles: () -> Void
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
                if !instance.authors.isEmpty {
                    Text("by \(instance.authors.joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                }
                if let targetVersion = instance.targetGameVersion, !targetVersion.isEmpty {
                    Text("DELTARUNE target \(targetVersion)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.75))
                }
                Text(instance.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
                Text("\(instance.payloads.count) Mac file\(instance.payloads.count == 1 ? "" : "s") in this instance")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                Text("CustomFiles mirrors Contents/Resources (for example, mus/)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                if !instance.warnings.isEmpty {
                    DisclosureGroup("Compatibility notes (\(instance.warnings.count))") {
                        ForEach(instance.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.system(size: 11))
                    .tint(.orange)
                }
            }
            Spacer(minLength: 10)
            VStack(spacing: 9) {
                Button(action: launch) {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 86)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(disabled)
                Button(action: showCustomFiles) {
                    Label("Show in Finder", systemImage: "folder")
                        .frame(minWidth: 112)
                }
                .buttonStyle(.bordered)
                .help("Add custom game files in the matching resource folders. They are applied only while this mod is running.")
                .disabled(disabled)
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
