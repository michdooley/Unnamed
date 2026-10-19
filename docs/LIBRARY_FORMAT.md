# Library format (version 2)

An Unnamed library is a folder. Anything that can read files can read it: this app, a future version, a script you write, or you in Finder. This document is the contract.

```
<Library>/
  library.json
  README.txt
  Folders/
    <folder-uuid>/
      folder.json
  Collections/
    <collection-uuid>/
      collection.json
      artwork-<8 hex>.jpg       optional
      Moodboard/                optional
        board.json
        Items/
          <item-uuid>.json
        Media/
          <file>                pictures (.heic or .jpg) and videos (.mov)
  Tracks/
    <track-uuid>/
      track.json
      <audio files>             every version, e.g. "idea.wav", "idea 2.wav"
      notes.md                  optional
      artwork-<8 hex>.jpg       optional
      Versions/
        <version-uuid>.json
      Waveforms/
        <version-uuid>.json
      Comments/
        <comment-uuid>.json
      waveform.json             format 1 only (see below)
```

## Rules

- **The folder name is the ID.** `Tracks/<uuid>/`, `Collections/<uuid>/` and `Folders/<uuid>/` are authoritative. An `id` inside the JSON is ignored if it disagrees, so a folder duplicated in Finder becomes a separate item.
- **Dates** are ISO 8601 in UTC, whole seconds (`2026-10-18T21:53:24Z`).
- **Readers ignore unknown keys, and missing keys get defaults**, so files written by newer or older versions still load. (The app doesn't keep unknown keys when it rewrites a file. Additions to the format should be optional.)
- **Writes are atomic** (write to a temporary file, then rename) and coordinated with `NSFileCoordinator`.
- **Deleting** a track, collection or folder moves its folder to the Trash. Deleting a version moves its audio file to the Trash. Deleting a comment removes its file.
- Files and folders that don't match this layout are ignored and left alone.

## `library.json`

```json
{ "format": "unnamed-library", "version": 2, "createdAt": "2026-10-18T21:53:24Z" }
```

Informational only. Libraries created by format 1 keep `"version": 1` and are read the same way.

## `track.json`

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | informational, see above |
| `title` | string | |
| `createdAt`, `updatedAt` | date | `createdAt` is when it was added to the library |
| `currentVersion` | UUID string | the version that plays by default; if missing or unknown, the newest |
| `audioFile`, `originalFileName`, `duration` | | copies of the current version's values, so format-1 readers still play it |
| `artworkFile` | string | file name inside the track folder |
| `artworkCredit` | credit | optional: who to credit for the artwork (below) |
| `bpm` | number | optional |
| `key` | string | optional, e.g. `"F♯ minor"` |
| `archivedAt` | date | optional: when the track was archived (see below) |

Every track belongs to at least one collection. A track that isn't listed in any `collection.json` (for example, while files are still syncing) is still shown in All Tracks.

## `Versions/<version-uuid>.json`

Every upload of a track's audio is kept, one file per version, so an edit to `track.json` on one device can never erase a version added on another.

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | unique within the track |
| `audioFile` | string | file name inside the track folder |
| `originalFileName` | string | name of the file as imported |
| `duration` | number | seconds |
| `createdAt` | date | |
| `name` | string | optional label, e.g. `"with Rhodes"` |

Versions are ordered by `createdAt` (ties by `id`), and a new version is always dated after the newest existing one, so "v1, v2, v3…" (position + 1) is stable. A track with no `Versions/` files (format 1) is read as a single version made from the top-level `audioFile` / `originalFileName` / `duration`. Its `id` is the track folder's ID, or `currentVersion` if `track.json` names one, which happens briefly while a newer track's version files are still syncing. New tracks get a version file straight away; format-1 tracks get them when a second version is added.

## `collection.json`

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | informational |
| `title` | string | |
| `createdAt`, `updatedAt` | date | |
| `tracks` | [UUID string] | ordered; a track may appear in many collections |
| `artworkFile` | string | file name inside the collection folder |
| `artworkCredit` | credit | optional: who to credit for the cover (below) |
| `folder` | UUID string | optional: the folder the collection is in |
| `archivedAt` | date | optional: when the collection was archived |

Track IDs that don't exist (for example, still syncing) are kept but not shown. Deleting a collection also deletes the tracks that aren't in any other collection.

An **artwork credit** is written when the art came from a photo service, so it can be shown next to the image:

```json
{ "source": "Unsplash", "author": "Jane Doe", "authorURL": "https://unsplash.com/@jane?…", "sourceURL": "https://unsplash.com/photos/…?…" }
```

## `folder.json`

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | informational |
| `title` | string | |
| `createdAt`, `updatedAt` | date | |
| `parent` | UUID string | optional: the folder this one is inside |
| `archivedAt` | date | optional: when the folder was archived |

Folders organize collections (tracks always live in collections). Folders form a tree. Each item records its own parent, so a move only rewrites the item that moved. Readers must be defensive: a `parent` or `folder` that doesn't exist means "top level". So does a `parent` that would form a loop, which can happen if two offline devices move folders into each other. Deleting a folder moves its contents up to its parent; nothing inside is deleted.

**Archiving** hides something without deleting it: an item with `archivedAt` set is left out of Home, All Tracks, search and playback, and listed under Archived instead. A track whose collections are all archived is hidden too. Archiving a folder hides everything inside it, without writing to the items inside, so restoring it (removing `archivedAt`) brings back exactly what was there. Items keep their place (`folder`, `parent`, collection membership) while archived.

## `Comments/<uuid>.json`

```json
{
  "id": "…",
  "timestamp": 21.5,
  "text": "bass too loud here",
  "createdAt": "2026-10-18T21:53:24Z",
  "author": "Michael",
  "version": "…"
}
```

`timestamp` is the position in seconds within the version the comment was made on (`version`). Comments without `version` (format 1) belong to the track's first version.

## `notes.md`

Free-form UTF-8 text, shared by all versions. An empty note is represented by the file not existing.

## `Waveforms/<version-uuid>.json`

```json
{ "version": 1, "peaks": [0, 12, 80, 255, …] }
```

Roughly 800 loudness values (RMS, normalized so the loudest is 255, with a gentle curve so quiet passages stay visible). It's derived from that version's audio and can be regenerated. It's stored so other devices can draw the waveform before the audio has downloaded. Format 1 kept a single `waveform.json`; if a track's first version has no file in `Waveforms/`, readers use `waveform.json`.

## Moodboards: `Collections/<uuid>/Moodboard/`

A collection's moodboard is a canvas measured in board units (a point at 100% zoom; x grows right, y grows down). Each thing on it is its own file in `Items/`, named by its UUID, so two devices editing different things never touch the same file.

`board.json`:

| key | type | notes |
| --- | --- | --- |
| `background` | string | `"#RRGGBB"` |
| `updatedAt` | date | |

`Items/<item-uuid>.json`:

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | informational; the file name is the ID |
| `type` | string | `track`, `image`, `video`, `text` or `drawing`. Readers skip types they don't know |
| `x`, `y` | number | tracks: where the thread starts; everything else: the top-left corner |
| `z` | number | stacking order, higher in front |
| `width`, `height` | number | images, videos: size. Text: `width` is the wrapping width |
| `track` | UUID string | tracks: which song |
| `thread` | [[x, y]] | tracks: the thread's knots relative to `x`, `y`, the first being `[0, 0]` |
| `file` | string | images, videos: a file in `Media/` |
| `text`, `fontSize` | string, number | text |
| `color` | string | text, drawings: `"#RRGGBB"`; text without one contrasts with the background |
| `points`, `lineWidth` | [[x, y]], number | drawings: the stroke relative to `x`, `y` |
| `createdAt`, `updatedAt` | date | |

A song is drawn as a thread: a centripetal Catmull–Rom curve through its knots. Its time runs evenly along the curve's length, start to end, which is where the playhead travels during playback. A new thread is a straight line of 5 units per second of music, between 280 and 1400 units. The journey plays the songs on the board in the collection's order (archived ones are skipped), regardless of shuffle. A track item whose song isn't in the collection (or no longer exists) is kept but not shown.

Pictures are stored as HEIC (JPEG where HEIC can't be written), at most 2048 pixels on the long side. Videos are re-encoded as HEVC (H.264 where HEVC isn't available) at most 1080p. Removing an item removes its JSON file; its media file is deleted once no item has named it for a day, so Undo, and devices still syncing, can find it. Which files are in use is read from the `file` key of every item file, whatever its type; while any item file can't be read, nothing is deleted.

## Sync and conflicts

The folder is meant to live in iCloud Drive, but any sync tool works. Data is split into many small files so that concurrent edits on two devices rarely collide. When iCloud does report a conflict on a JSON file, the version with the newest modification date wins and the others are discarded.
