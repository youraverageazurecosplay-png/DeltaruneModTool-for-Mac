import CryptoKit
import Foundation

@main
struct ModModelsValidation {
    static func main() throws {
        try validateSafePaths()
        try validateCustomFiles()
        try validateModArchive()
        try validateGameBananaModels()
        try validateOptionalGameBananaArchive()
        print("Mod manager validation passed.")
    }

    private static func validateSafePaths() throws {
        guard try SafePaths.relative("./chapter3_windows/data.win") == "chapter3_windows/data.win" else {
            throw validationError("Valid relative path was not normalized.")
        }
        do {
            _ = try SafePaths.relative("./chapter3_windows/../data.win")
            throw validationError("Path traversal was accepted.")
        } catch ModManagerError.unsafePath {
        }
        do {
            _ = try SafePaths.relative("/tmp/data.win")
            throw validationError("Absolute path was accepted.")
        } catch ModManagerError.unsafePath {
        }
    }

    private static func validateCustomFiles() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("DMT-CustomFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let customRoot = temporaryRoot.appendingPathComponent("CustomFiles", isDirectory: true)
        let musicDirectory = customRoot.appendingPathComponent("mus", isDirectory: true)
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        let musicFile = musicDirectory.appendingPathComponent("custom.ogg")
        try Data("custom music".utf8).write(to: musicFile)

        let files = try ModCustomFiles.files(in: customRoot)
        try require(files["mus/custom.ogg"] == musicFile, "Custom resource paths weren't mapped from the Finder folder.")

        let outsideFile = temporaryRoot.appendingPathComponent("outside.ogg")
        try Data("outside".utf8).write(to: outsideFile)
        try fileManager.createSymbolicLink(
            at: customRoot.appendingPathComponent("linked.ogg"),
            withDestinationURL: outsideFile
        )
        do {
            _ = try ModCustomFiles.files(in: customRoot)
            throw validationError("A symbolic link in the custom-files folder was accepted.")
        } catch ModManagerError.unsafePath {
        }
    }

    private static func validateModArchive() throws {
        guard let xdelta = DeltaModBuilder.xdeltaExecutable() else {
            throw validationError("xdelta3 is not installed.")
        }
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("DMT-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let windowsFolder = temporaryRoot.appendingPathComponent("Windows", isDirectory: true)
        let windowsChapter = windowsFolder.appendingPathComponent("chapter3_windows", isDirectory: true)
        let backupRoot = temporaryRoot.appendingPathComponent("Backups", isDirectory: true)
        let modFolder = temporaryRoot.appendingPathComponent("Mod", isDirectory: true)
        let appSupport = temporaryRoot.appendingPathComponent("AppData", isDirectory: true)
        try fileManager.createDirectory(at: windowsChapter, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modFolder, withIntermediateDirectories: true)

        let source = windowsChapter.appendingPathComponent("data.win")
        let target = temporaryRoot.appendingPathComponent("patched-data.win")
        try Data("original chapter source".utf8).write(to: source)
        try Data("patched chapter contents".utf8).write(to: target)
        try WindowsBackup.backup(from: windowsFolder, to: backupRoot)

        let deltaPatch = modFolder.appendingPathComponent("chapter3.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", source.path, target.path, deltaPatch.path]
        )
        try Data("extra mod music".utf8).write(to: modFolder.appendingPathComponent("extra.ogg"))
        try Data("windows dll".utf8).write(to: modFolder.appendingPathComponent("helper.dll"))
        try Data([137, 80, 78, 71]).write(to: modFolder.appendingPathComponent("_icon.png"))
        try Data("""
        {
          "metadata": {
            "name": "Test Chapter Mod",
            "version": "2.0",
            "description": "A test mod",
            "author": ["Test Author"]
          },
          "deltaruneTargetVersion": "1.06"
        }
        """.utf8).write(to: modFolder.appendingPathComponent("_deltamodinfo.json"))
        try Data("""
        <patch type="xdelta" patch="./chapter3.xdelta" to="./chapter3_windows/data.win" />
        <patch type="override" patch="./extra.ogg" to="./mus/extra.ogg" />
        <patch type="override" patch="./helper.dll" to="./chapter3_windows/helper.dll" />
        """.utf8).write(to: modFolder.appendingPathComponent("modding.xml"))

        let archive = temporaryRoot.appendingPathComponent("test.deltamod")
        try makeArchive(from: modFolder, at: archive)
        let result = try DeltaModBuilder.build(
            archive: archive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )

        try require(result.instance.name == "Test Chapter Mod", "Mod metadata was not read.")
        try require(result.instance.targetGameVersion == "1.06", "Target game version was not read.")
        try require(result.instance.iconFile != nil, "Mod icon was not imported.")
        try require(
            Set(result.instance.payloads.map(\.resourcePath)) == Set(["chapter3_mac/game.ios", "mus/extra.ogg"]),
            "Patch or override destinations were incorrect."
        )
        try require(try DeltaModBuilder.isDeltamodArchive(archive), "Deltamod archive wasn't recognized.")
        try require(result.instance.warnings.contains { $0.contains("helper.dll") }, "Windows DLL was not reported.")

        let chapterPayload = try requirePayload("chapter3_mac/game.ios", in: result.instance)
        let patchedPayload = result.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(chapterPayload.instanceFile)
        try require(
            try Data(contentsOf: patchedPayload) == Data("patched chapter contents".utf8),
            "xdelta output differs from expected patched data."
        )

        let musicPayload = try requirePayload("mus/extra.ogg", in: result.instance)
        let copiedMusic = result.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(musicPayload.instanceFile)
        try require(
            try Data(contentsOf: copiedMusic) == Data("extra mod music".utf8),
            "Override file was not copied into the instance."
        )

        let g3mFolder = temporaryRoot.appendingPathComponent("G3MMod", isDirectory: true)
        try fileManager.createDirectory(at: g3mFolder, withIntermediateDirectories: true)
        try fileManager.copyItem(at: deltaPatch, to: g3mFolder.appendingPathComponent("chapter3.xdelta"))
        try fileManager.copyItem(
            at: modFolder.appendingPathComponent("extra.ogg"),
            to: g3mFolder.appendingPathComponent("extra.ogg")
        )
        try fileManager.copyItem(
            at: modFolder.appendingPathComponent("_icon.png"),
            to: g3mFolder.appendingPathComponent("icon.png")
        )
        let g3mConfig: [String: Any] = [
            "config_version": "2.0.0",
            "id": "test_g3m_mod",
            "name": "Test G3M Mod",
            "version": "1.2.0",
            "authors": ["G3M Tester"],
            "game": "deltarune",
            "game_version": "1.06",
            "icon": "${mod_path}/icon.png",
            "files": [
                [
                    "Chapter 3": [
                        [
                            "source": "${mod_path}/chapter3.xdelta",
                            "target": "${game_path}/chapter3_windows/data.win",
                            "type": "patch",
                            "source_hash": try sha256(g3mFolder.appendingPathComponent("chapter3.xdelta")),
                            "target_hash": try sha256(source)
                        ],
                        [
                            "source": "${mod_path}/extra.ogg",
                            "target": "${game_path}/mus/extra.ogg",
                            "type": "overwrite"
                        ]
                    ]
                ],
                ["source": "${mod_path}/README.md", "type": "info"]
            ]
        ]
        let g3mConfigURL = g3mFolder.appendingPathComponent("mod_config.json")
        try JSONSerialization.data(withJSONObject: g3mConfig, options: [.prettyPrinted, .sortedKeys])
            .write(to: g3mConfigURL)
        let g3mArchive = temporaryRoot.appendingPathComponent("test-g3m.zip")
        try makeArchive(from: g3mFolder, at: g3mArchive)
        try require(try DeltaModBuilder.archiveKind(g3mArchive) == .g3m, "G3M package wasn't recognized.")
        let g3mInstance = try DeltaModBuilder.build(
            archive: g3mArchive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        try require(g3mInstance.instance.name == "Test G3M Mod", "G3M metadata wasn't imported.")
        try require(g3mInstance.instance.iconFile != nil, "G3M icon wasn't imported.")
        try require(
            Set(g3mInstance.instance.payloads.map(\.resourcePath)) == Set([
                "chapter3_mac/game.ios",
                "mus/extra.ogg"
            ]),
            "G3M chapter patch or overwrite destinations were incorrect."
        )
        let g3mChapter = try requirePayload("chapter3_mac/game.ios", in: g3mInstance.instance)
        let g3mPatchedData = g3mInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(g3mChapter.instanceFile)
        try require(
            try Data(contentsOf: g3mPatchedData) == Data("patched chapter contents".utf8),
            "G3M xdelta output differs from expected patched data."
        )

        let legacyG3MFolder = temporaryRoot.appendingPathComponent("LegacyG3M", isDirectory: true)
        try fileManager.createDirectory(at: legacyG3MFolder, withIntermediateDirectories: true)
        let legacyTarget = Data("legacy G3M patched chapter".utf8)
        let legacyPatch = legacyG3MFolder.appendingPathComponent("chapter3.bps")
        try makeBPSPatch(source: Data(contentsOf: source), target: legacyTarget, at: legacyPatch)
        let sourceChecksum = String(try sha256(source).dropFirst("sha256:".count))
        try Data("""
        name = "Legacy G3M Patch"
        version = "1.0"
        description = "Legacy package test"
        author = ["G3M Tester"]

        [[neededFiles]]
        file = "./chapter3_windows/data.win"
        checksum = "\(sourceChecksum)"
        """.utf8).write(to: legacyG3MFolder.appendingPathComponent("meta.toml"))
        try Data("""
        <patch type="bps" patch="./chapter3.bps" to="./chapter3_windows/data.win" />
        """.utf8).write(to: legacyG3MFolder.appendingPathComponent("modding.xml"))
        let legacyG3MArchive = temporaryRoot.appendingPathComponent("legacy-g3m.zip")
        try makeArchive(from: legacyG3MFolder, at: legacyG3MArchive)
        try require(
            try DeltaModBuilder.archiveKind(legacyG3MArchive) == .legacyG3M,
            "Legacy G3M package wasn't recognized."
        )
        let legacyInstance = try DeltaModBuilder.build(
            archive: legacyG3MArchive,
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        try require(legacyInstance.instance.name == "Legacy G3M Patch", "Legacy G3M TOML metadata wasn't read.")
        let legacyPayload = try requirePayload("chapter3_mac/game.ios", in: legacyInstance.instance)
        let legacyPatchedData = legacyInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(legacyPayload.instanceFile)
        try require(
            try Data(contentsOf: legacyPatchedData) == legacyTarget,
            "Legacy G3M BPS output differs from expected patched data."
        )

        var invalidG3MConfig = g3mConfig
        guard var invalidGroups = invalidG3MConfig["files"] as? [[String: Any]],
              var invalidChapter = invalidGroups[0]["Chapter 3"] as? [[String: Any]] else {
            throw validationError("Test G3M configuration could not be modified.")
        }
        invalidChapter[0]["source_hash"] = "sha256:" + String(repeating: "0", count: 64)
        invalidGroups[0]["Chapter 3"] = invalidChapter
        invalidG3MConfig["files"] = invalidGroups
        try JSONSerialization.data(withJSONObject: invalidG3MConfig, options: [.prettyPrinted, .sortedKeys])
            .write(to: g3mConfigURL)
        let invalidG3MArchive = temporaryRoot.appendingPathComponent("invalid-g3m.zip")
        try makeArchive(from: g3mFolder, at: invalidG3MArchive)
        do {
            _ = try DeltaModBuilder.build(
                archive: invalidG3MArchive,
                windowsBackup: backupRoot,
                supportRoot: appSupport
            )
            throw validationError("A mismatched G3M source hash was accepted.")
        } catch ModManagerError.invalidArchive {
        }

        let manualTarget = temporaryRoot.appendingPathComponent("manual-patched-data.win")
        try Data("manual chapter three".utf8).write(to: manualTarget)
        let manualPatch = temporaryRoot.appendingPathComponent("chapter3_manual.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", source.path, manualTarget.path, manualPatch.path]
        )
        try require(
            try DeltaModBuilder.manualPatchOptions(archive: manualPatch, supportRoot: appSupport)
                .map(\.path) == [manualPatch.lastPathComponent],
            "A standalone xdelta wasn't offered as a selectable patch."
        )
        let manualArchiveFolder = temporaryRoot.appendingPathComponent("ManualMod", isDirectory: true)
        try FileManager.default.createDirectory(at: manualArchiveFolder, withIntermediateDirectories: true)
        let windowsChapter2 = windowsFolder.appendingPathComponent("chapter2_windows", isDirectory: true)
        try fileManager.createDirectory(at: windowsChapter2, withIntermediateDirectories: true)
        let source2 = windowsChapter2.appendingPathComponent("data.win")
        try Data("chapter two source".utf8).write(to: source2)
        try WindowsBackup.backup(from: windowsFolder, to: backupRoot)
        try Data("{\"test\":\"green ralsei language override\"}".utf8)
            .write(to: manualArchiveFolder.appendingPathComponent("lang_en.json"))

        let manualTarget2 = temporaryRoot.appendingPathComponent("manual-patched-data-ch2.win")
        try Data("manual chapter two".utf8).write(to: manualTarget2)
        let manualPatch2 = temporaryRoot.appendingPathComponent("chapter2_manual.xdelta")
        try run(
            executable: xdelta,
            arguments: ["-e", "-s", source2.path, manualTarget2.path, manualPatch2.path]
        )
        try FileManager.default.copyItem(
            at: manualPatch2,
            to: manualArchiveFolder.appendingPathComponent(manualPatch2.lastPathComponent)
        )
        try FileManager.default.copyItem(
            at: manualPatch,
            to: manualArchiveFolder.appendingPathComponent(manualPatch.lastPathComponent)
        )
        let manualArchive = temporaryRoot.appendingPathComponent("manual.zip")
        try makeArchive(from: manualArchiveFolder, at: manualArchive)
        try require(!DeltaModBuilder.isDeltamodArchive(manualArchive), "Manual archive was treated as a Deltamod.")
        let manualOptions = try DeltaModBuilder.manualPatchOptions(
            archive: manualArchive,
            supportRoot: appSupport
        )
        try require(
            manualOptions.map(\.path) == ["chapter2_manual.xdelta", "chapter3_manual.xdelta"],
            "Manual archive analysis returned \(manualOptions.map(\.path)) instead of all xdelta patch names."
        )
        try require(
            manualOptions.compactMap(\.suggestedChapter) == [2, 3],
            "Chapter numbers in manual patch filenames weren't detected."
        )
        try require(
            ManualPatchOption(path: "Chapter1LocalMultiplayerVer11_5.xdelta").suggestedChapter == 1,
            "A chapter number directly followed by a filename suffix wasn't detected."
        )
        let manualInstance = try DeltaModBuilder.buildManual(
            archive: manualArchive,
            assignments: [
                ManualPatchAssignment(patchPath: "chapter3_manual.xdelta", chapter: 3),
                ManualPatchAssignment(patchPath: "chapter2_manual.xdelta", chapter: 2)
            ],
            modName: "Manual Test Mod",
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        for (resourcePath, expected) in [
            ("chapter3_mac/game.ios", "manual chapter three"),
            ("chapter2_mac/game.ios", "manual chapter two")
        ] {
            let payload = try requirePayload(resourcePath, in: manualInstance.instance)
            let output = manualInstance.directory.appendingPathComponent("Payloads")
                .appendingPathComponent(payload.instanceFile)
            try require(
                try Data(contentsOf: output) == Data(expected.utf8),
                "\(resourcePath) wasn't patched from its selected xdelta."
            )
        }

        let windowsChapter4 = windowsFolder.appendingPathComponent("chapter4_windows", isDirectory: true)
        try fileManager.createDirectory(at: windowsChapter4, withIntermediateDirectories: true)
        try Data("chapter four source".utf8).write(to: windowsChapter4.appendingPathComponent("data.win"))
        try WindowsBackup.backup(from: windowsFolder, to: backupRoot)
        let dataWinArchiveFolder = temporaryRoot.appendingPathComponent("DataWinMod", isDirectory: true)
        let dataWinSourceDirectory = dataWinArchiveFolder
            .appendingPathComponent("Chapter4_windows", isDirectory: true)
        try fileManager.createDirectory(at: dataWinSourceDirectory, withIntermediateDirectories: true)
        let replacementData = Data("complete chapter four data.win replacement".utf8)
        try replacementData.write(to: dataWinSourceDirectory.appendingPathComponent("data.win"))
        let dataWinArchive = temporaryRoot.appendingPathComponent("data-win-mod.zip")
        try makeArchive(from: dataWinArchiveFolder, at: dataWinArchive)
        let dataWinOptions = try DeltaModBuilder.manualPatchOptions(
            archive: dataWinArchive,
            supportRoot: appSupport
        )
        try require(
            dataWinOptions.count == 1
                && dataWinOptions[0].kind == .dataWin
                && dataWinOptions[0].suggestedChapter == 4,
            "A chapter-specific data.win wasn't detected as an assignable full replacement."
        )
        let replacementInstance = try DeltaModBuilder.buildManual(
            archive: dataWinArchive,
            assignments: [
                ManualPatchAssignment(
                    patchPath: "Chapter4_windows/data.win",
                    chapter: 4,
                    kind: .dataWin
                )
            ],
            modName: "Raw data.win Replacement",
            windowsBackup: backupRoot,
            supportRoot: appSupport
        )
        let replacementPayload = try requirePayload("chapter4_mac/game.ios", in: replacementInstance.instance)
        let replacementFile = replacementInstance.directory.appendingPathComponent("Payloads")
            .appendingPathComponent(replacementPayload.instanceFile)
        try require(
            try Data(contentsOf: replacementFile) == replacementData,
            "A selected data.win wasn't copied as a full chapter replacement."
        )
        for chapter in [2, 3] {
            let languagePayload = try requirePayload(
                "chapter\(chapter)_mac/lang/lang_en.json",
                in: manualInstance.instance
            )
            let languageOutput = manualInstance.directory.appendingPathComponent("Payloads")
                .appendingPathComponent(languagePayload.instanceFile)
            try require(
                try Data(contentsOf: languageOutput) == Data("{\"test\":\"green ralsei language override\"}".utf8),
                "Manual language override wasn't included in Chapter \(chapter)."
            )
        }
    }

    private static func validateGameBananaModels() throws {
        let listing = Data("""
        {
          "_idRow": 662826,
          "_sName": "Kaizo Roaring Knight (3.0)",
          "_sProfileUrl": "https://gamebanana.com/mods/662826",
          "_bHasFiles": true,
          "_aPreviewMedia": {
            "_aImages": [{
              "_sBaseUrl": "https://images.gamebanana.com/img/ss/mods",
              "_sFile530": "sample.jpg"
            }]
          },
          "_aSubmitter": {"_sName": "EnderCat8"},
          "_aRootCategory": {"_sName": "Difficulty Changes"},
          "_nLikeCount": 12,
          "_nViewCount": 1234
        }
        """.utf8)
        let mod = try JSONDecoder().decode(GameBananaMod.self, from: listing)
        try require(mod.id == 662826, "GameBanana mod id wasn't decoded.")
        try require(mod.category == "Difficulty Changes", "GameBanana category wasn't decoded.")
        try require(mod.author == "EnderCat8", "GameBanana creator wasn't decoded.")
        try require(
            mod.imageURL?.absoluteString == "https://images.gamebanana.com/img/ss/mods/sample.jpg",
            "GameBanana preview image wasn't decoded."
        )
        try require(GameBananaSort.relevance.apiValue == "best_match", "Relevance wasn't mapped to GameBanana's global order.")
        try require(GameBananaSort.popularity.apiValue == "popularity", "Popularity wasn't mapped to GameBanana's global order.")
        try require(GameBananaSort.newest.apiValue == "date", "Newest wasn't mapped to GameBanana's global order.")
        try require(GameBananaSort.recentlyUpdated.apiValue == "udate", "Recently updated wasn't mapped to GameBanana's global order.")
        guard let oneClick = GameBananaOneClickLink(
            url: URL(string: "g3m://https//gamebanana.com/mmdl/1863022,Mod,730367?toolid=20615")!
        ) else {
            throw validationError("G3M GameBanana one-click link wasn't parsed.")
        }
        try require(
            oneClick.fileID == 1_863_022 && oneClick.modID == 730_367,
            "G3M one-click IDs were parsed incorrectly."
        )
        guard let legacyOneClick = GameBananaOneClickLink(
            url: URL(string: "deltahub://https//www.gamebanana.com/mmdl/123,Mod,456?toolid=1")!
        ) else {
            throw validationError("Legacy DELTAHUB one-click link wasn't parsed.")
        }
        try require(
            legacyOneClick.fileID == 123 && legacyOneClick.modID == 456,
            "Legacy one-click IDs were parsed incorrectly."
        )
        try require(
            GameBananaOneClickLink(url: URL(string: "g3m://https//example.com/mmdl/1,Mod,2")!) == nil,
            "An external host was accepted as a GameBanana one-click link."
        )
        try require(
            GameBananaPagination.resultsPerPage * GameBananaPagination.initialPageCount == 30
                && GameBananaPagination.prefetchCount == 15,
            "GameBanana pagination didn't match the initial 30 and 15-result prefetch."
        )
        try require(
            GameBananaPagination.shouldPrefetch(visibleIndex: 15, loadedCount: 30)
                && !GameBananaPagination.shouldPrefetch(visibleIndex: 14, loadedCount: 30),
            "The catalog prefetch threshold wasn't at 15 remaining results."
        )

        let item = Data("""
        {
          "_sName": "Kaizo Roaring Knight (3.0)",
          "_sProfileUrl": "https://gamebanana.com/mods/662826",
          "_sDescription": "A test description",
          "_aFiles": [{
            "_idRow": 1847726,
            "_sFile": "kaizo_knight_v3_0-deltamod.zip",
            "_nFilesize": 34542670,
            "_sDownloadUrl": "https://gamebanana.com/dl/1847726",
            "_bIsArchived": false,
            "_sVersion": "3.0",
            "_sDescription": "Latest version"
          }, {
            "_idRow": 1847000,
            "_sFile": "kaizo_knight_v2_0-deltamod.zip",
            "_nFilesize": 2000,
            "_sDownloadUrl": "https://gamebanana.com/dl/1847000",
            "_bIsArchived": true,
            "_sDescription": "Old version"
          }]
        }
        """.utf8)
        let details = try JSONDecoder().decode(GameBananaItemDetails.self, from: item)
        try require(details.files.count == 2, "GameBanana release list wasn't decoded.")
        try require(details.files[0].isDeltamod, "Deltamod release wasn't recognized.")
        try require(!details.files[0].isArchived, "Current release was marked archived.")
        try require(details.files[0].isActiveDeltamod, "Current Deltamod wasn't marked compatible.")
        try require(details.files[0].releaseTitle == "Version 3.0", "GameBanana release version wasn't shown.")
        try require(
            details.files[1].isSelectableRelease && !details.files[1].isSupportedRelease,
            "An archived but supported version wasn't selectable separately from compatibility checks."
        )
        let manualFile = GameBananaFile(
            id: 1,
            name: "manual-patch.zip",
            size: 20,
            downloadURL: URL(string: "https://gamebanana.com/dl/1")!,
            isArchived: false,
            version: nil,
            description: nil,
            dateAdded: nil
        )
        try require(manualFile.isManualPatchDownload, "Manual ZIP download wasn't recognized.")
        let offlineError = NSError(
            domain: NSURLErrorDomain,
            code: URLError.notConnectedToInternet.rawValue
        )
        try require(
            GameBananaError.message(for: offlineError) == "Game Offline! Try Again Later.",
            "Offline GameBanana errors weren't mapped to the requested message."
        )
        let serverError = NSError(domain: "GameBanana", code: 503)
        try require(
            GameBananaError.message(for: serverError) != GameBananaError.offlineMessage,
            "A server error was incorrectly reported as offline."
        )
    }

    private static func validateOptionalGameBananaArchive() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["DMT_TEST_DELTAMOD_ARCHIVE"],
              let backupPath = ProcessInfo.processInfo.environment["DMT_TEST_WINDOWS_BACKUP"] else {
            return
        }
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DMT-Live-Archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let result = try DeltaModBuilder.build(
            archive: URL(fileURLWithPath: archivePath),
            windowsBackup: URL(fileURLWithPath: backupPath),
            supportRoot: supportRoot
        )
        try require(!result.instance.name.isEmpty, "Live GameBanana metadata wasn't read.")
        try require(
            result.instance.payloads.contains { $0.resourcePath == "chapter3_mac/game.ios" },
            "Live GameBanana xdelta wasn't assigned to Chapter 3."
        )
    }

    private static func makeArchive(from directory: URL, at archive: URL) throws {
        let script = """
        import os, sys, zipfile
        root, output = sys.argv[1], sys.argv[2]
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as package:
            for current, _, names in os.walk(root):
                for name in names:
                    path = os.path.join(current, name)
                    package.write(path, os.path.relpath(path, root))
        """
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, directory.path, archive.path]
        )
    }

    private static func run(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw validationError(details)
        }
    }

    private static func requirePayload(_ path: String, in instance: ModInstance) throws -> ModPayload {
        guard let payload = instance.payloads.first(where: { $0.resourcePath == path }) else {
            throw validationError("Missing payload \(path).")
        }
        return payload
    }

    private static func sha256(_ file: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: file))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeBPSPatch(source: Data, target: Data, at destination: URL) throws {
        var patch = Data("BPS1".utf8)
        patch.append(contentsOf: encodeBPSNumber(UInt64(source.count)))
        patch.append(contentsOf: encodeBPSNumber(UInt64(target.count)))
        patch.append(contentsOf: encodeBPSNumber(0))
        patch.append(contentsOf: encodeBPSNumber((UInt64(target.count - 1) << 2) | 1))
        patch.append(target)
        patch.appendLittleEndian(crc32(source))
        patch.appendLittleEndian(crc32(target))
        patch.appendLittleEndian(crc32(patch))
        try patch.write(to: destination)
    }

    private static func encodeBPSNumber(_ value: UInt64) -> [UInt8] {
        var value = value
        var result: [UInt8] = []
        while true {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value == 0 {
                byte |= 0x80
                result.append(byte)
                return result
            }
            result.append(byte)
            value -= 1
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw validationError(message)
        }
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(
            domain: "DeltaruneModManagerValidation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
