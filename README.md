# DELTARUNE Mod Manager

A native macOS SwiftUI launcher for GameBanana DELTARUNE mods. It reads
Deltamod archives and modern or legacy G3M packages, applies supported patches
to backed-up Windows chapter data, maps Mac-compatible overrides into the
matching Mac game resources, and creates a separate launchable instance for
each mod.

## Requirements

- macOS 13 or later
- Steam-installed Mac `DELTARUNE.app`
- A Windows DELTARUNE folder containing `chapterN_windows/data.win`
- `xdelta3` (`brew install xdelta`) for xdelta patches; BPS patches are applied natively

Install DELTARUNE through Steam first. Steam handles account ownership and
official game downloads; this project does not redistribute or download game
files. Choose your local Windows game folder and Steam-installed Mac app during
first-run setup. The project keeps the `Base Game` directory out of source
control.

## Build and run

```sh
./scripts/build-app.sh
open "Deltarune Mod Manager.app"
```

Build a macOS Installer package that installs only the mod manager into
`/Applications`:

```sh
./scripts/package-app.sh
```

The generated `Deltarune Mod Manager.pkg` does not include DELTARUNE files.
The app uses the supplied title-screen artwork as a darkened background and
your supplied red heart image as its app icon.

Run the patcher/archive validation with:

```sh
./scripts/test-mod-builder.sh
```

The app backs up the Windows chapter `data.win` files into its Application
Support directory during setup. It does not patch the live Mac installation
when importing a mod. On launch, it saves the original Mac files, temporarily
installs the selected instance, opens the Mac game app, and restores the
originals when the game exits. A recovery record is kept so the app can restore
files on its next start if it was quit unexpectedly.

Use the native GameBanana catalog's search and category tabs to find mods.
Sorting is applied by GameBanana before pagination, so relevance, popularity,
newest, and recently updated results stay in global order as more pages load.
The catalog loads 30 mods initially, then preloads 15 more when you reach the
middle of the loaded results. The GameBanana search API does not provide a
global sort by view count. Mod details show each supported release as an
expandable version choice, including archived versions.
GameBanana G3M one-click links (`g3m://…/mmdl/<fileID>,Mod,<modID>`) and legacy
`deltahub://` links open this app and install the specific linked release.
Deltamod packages, modern G3M ZIPs containing `mod_config.json`, and legacy
G3M packages containing `modding.xml` plus `meta.toml` are detected and
imported automatically. G3M packages support DELTARUNE chapter patches using
xdelta or BPS, complete data-file replacements, supported `overwrite` file
actions, and package/source checksums. G3M resource patches (`.g3mpatch`),
scripts, directory/archive operations, and unsupported operation types are
reported instead of run.

Other manual ZIP and xdelta releases are downloaded or selected first, then
analyzed for all `.xdelta` patches. Chapter numbers in patch names are selected
automatically, and assignments can still be changed or skipped before creating
the instance; each selected patch is applied to that chapter's backed-up Windows
`data.win`. Manual patch ZIPs with `lang_*.json` files also
apply those language overrides to every selected chapter. **Only compatible
mods** includes active Deltamod, G3M, and manual patch releases. You can
also import a `.deltamod`, G3M ZIP, regular ZIP, or xdelta manually. Windows-only
DLL overrides are skipped; unsupported patch formats and missing chapter
sources are reported rather than silently applied.

Downloaded archives are removed after successful installation and old failed
downloads are cleaned up after seven days. GameBanana responses and images use
a bounded URL cache to limit memory and cache-disk usage; installed instances
and Windows backups are retained until you remove them. Use an instance's
**Show in Finder** button to open its `CustomFiles` folder; place files there
using paths relative to the game's `Contents/Resources` folder (for example,
`CustomFiles/mus/custom.ogg`). These custom files override that instance's
managed files only while it is running, and originals are restored afterward.
