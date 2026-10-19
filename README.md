# Unnamed

An open-source home for your music ideas: voice memos, bounces, sketches and demos. Upload audio, organize it into collections (albums, EPs, mixtapes), and play it back with a SoundCloud-style waveform. Leave timestamped comments and notes.

Your library is **a plain folder you own**. Put it in iCloud Drive and it syncs to your other devices through your own iCloud account. There's no server, no subscription, and nothing trains on your music.

![The collection page](docs/images/collection.png)

| Version history | Folders | Welcome screen |
| --- | --- | --- |
| ![Versions](docs/images/versions.png) | ![A folder](docs/images/folder.png) | ![Spinning CDs](docs/images/welcome.jpg) |

## Features

- **Import** WAV, MP3, AIFF, M4A/AAC, FLAC, CAF, or anything else macOS can play. Use the Add Tracks button, drag files or whole folders into the window, drop them on the Dock icon, or use Open With.
- **Collections**: albums, EPs, mixtapes, sets of sketches. A track can be in several collections. Reorder by dragging, add tracks you've already uploaded, and move or duplicate tracks between collections.
- **Folders** for organizing. A folder can hold subfolders, collections and loose tracks, nested as deep as you like. Drag things into folders in the sidebar or on a folder's page.
- **Version history**: upload a new version of a track and the old ones are kept. Play any version, name it ("rough mix", "with vocals"), make it current again, or export it. Comments belong to the version they were made on.
- **Artwork** for collections and individual tracks. Click the cover or drop an image on it. Tracks without their own art take on their collection's look.
- **Waveform player**: a floating player with a scrubbable waveform, play/pause, next/previous, shuffle, repeat (all/one), volume and an up-next queue. Media keys and Control Center work too.
- **Timestamped comments**: start typing while a track plays and the comment pins to that moment (and that version). Comments show as markers on the waveform; click one to jump there.
- **Notes** per track, for lyrics, chords and to-dos.
- **Search** across titles, file names, notes, comments, key and BPM.
- **iCloud aware**: tracks that aren't downloaded yet show a cloud badge and download when played. Use "Make available offline" / "Remove download" to manage space.
- **Export** a track (or any version), or a whole collection as numbered files. Drag a track straight into Finder or your DAW.
- **A Metal welcome screen**: slowly spinning CDs, drawn per pixel with a small diffraction model, whose rainbow sheen follows your mouse.

## Getting started

Requirements: macOS 15 or later, and Xcode 16 or later to build. Xcode 26 ships the Metal compiler separately; if the build says it's missing, run `xcodebuild -downloadComponent MetalToolchain`.

```sh
git clone <this repo>
open Unnamed.xcodeproj
```

Press Run. On first launch, choose **Create Library in iCloud Drive…** (or pick any folder if you don't want sync).

To try the app without your own files, add `-demoLibrary` under *Product › Scheme › Edit Scheme › Arguments* (Debug builds only). This opens a throwaway library of synthesized ideas.

### Signing

Out of the box the app is signed to run locally, with no Apple account needed. To sign with your own team (which also keeps macOS remembering your library folder between rebuilds), create `Config/Signing.local.xcconfig`, which git ignores:

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.Unnamed
```

A free Apple ID is enough. The app doesn't use CloudKit or any paid capability.

## How sync works

The library is ordinary files (see [docs/LIBRARY_FORMAT.md](docs/LIBRARY_FORMAT.md)):

```
Unnamed Library/
  Tracks/<id>/        every version's audio, track.json, notes.md, Comments/*.json, Waveforms/*.json, artwork
  Collections/<id>/   collection.json (ordered track ids), artwork
  Folders/<id>/       folder.json (title and parent folder)
```

iCloud Drive moves the files between devices. The app watches the folder, picks up changes as they arrive, and writes through `NSFileCoordinator` the way iCloud expects. Each comment is its own file, and notes are separate from metadata, so edits made on two devices at once rarely touch the same file. When they do, the newest version wins.

Why not CloudKit? CloudKit needs a paid Apple Developer membership for every person who builds the app. It would also put your library in a database only this app can read. A folder works with a free account and stays readable without the app. You can back it up, move it, or share it as an iCloud Drive shared folder to collaborate.

## Project layout

```
Packages/UnnamedKit/   Platform-independent core, shared with the future iPhone app
  Models, LibraryLayout          the on-disk format
  LibraryDisk                    file I/O actor: coordinated writes, cached scans, conflicts
  LibraryStore (+Folders, +Versions)  observable in-memory library, mutations, sync
  AudioAnalyzer                  duration + waveform peaks
  PlaybackQueue, PlayerController  queue rules, AVPlayer, Now Playing
Unnamed/               macOS app (SwiftUI)
  App/        app entry, menus, AppModel (navigation, panels), debug helpers
  Views/      Home, collection page, track details, player bar, search, settings
  Components/ waveform, disc, artwork, drag and drop, layout, CD shader (Metal)
Config/                Info.plist, entitlements, signing
```

Run the core tests:

```sh
cd Packages/UnnamedKit && swift test
```

The Xcode project uses synchronized folders, so new files under `Unnamed/` are picked up without editing the project.

## Roadmap

- iPhone app sharing `UnnamedKit` (opens the same iCloud Drive folder)
- Recording straight into the app
- Sharing a collection by link
- Optional CloudKit backend for people with a developer account

## License

MIT. See [LICENSE](LICENSE).
