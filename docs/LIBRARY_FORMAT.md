# Library format (version 1)

An Unnamed library is a folder. Anything that can read files can read it: this app, a future version, a script you write, or you in Finder. This document is the contract.

```
<Library>/
  library.json
  README.txt
  Tracks/
    <track-uuid>/
      track.json
      <audio file>              e.g. "2023-08-15 atmos.wav"
      notes.md                  optional
      waveform.json             optional
      artwork-<8 hex>.jpg       optional
      Comments/
        <comment-uuid>.json
  Collections/
    <collection-uuid>/
      collection.json
      artwork-<8 hex>.jpg       optional
```

## Rules

- **The folder name is the ID.** `Tracks/<uuid>/` and `Collections/<uuid>/` are authoritative. An `id` inside the JSON is ignored if it disagrees, so a folder duplicated in Finder becomes a separate item.
- **Dates** are ISO 8601 in UTC, whole seconds (`2026-10-18T21:53:24Z`).
- **Readers ignore unknown keys, and missing keys get defaults**, so files written by newer or older versions still load. (Version 1 of the app doesn't keep unknown keys when it rewrites a file. Additions to the format should be optional.)
- **Writes are atomic** (write to a temporary file, then rename) and coordinated with `NSFileCoordinator`.
- **Deleting** a track or collection moves its folder to the Trash. Deleting a comment removes its file.
- Files and folders that don't match this layout are ignored and left alone.

## `library.json`

```json
{ "format": "unnamed-library", "version": 1, "createdAt": "2026-10-18T21:53:24Z" }
```

## `track.json`

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | informational, see above |
| `title` | string | |
| `createdAt`, `updatedAt` | date | `createdAt` is when it was added to the library |
| `audioFile` | string | file name inside the track folder |
| `originalFileName` | string | name of the file as imported |
| `duration` | number | seconds |
| `artworkFile` | string | file name inside the track folder |
| `bpm` | number | optional |
| `key` | string | optional, e.g. `"F♯ minor"` |

## `collection.json`

| key | type | notes |
| --- | --- | --- |
| `id` | UUID string | informational |
| `title` | string | |
| `createdAt`, `updatedAt` | date | |
| `tracks` | [UUID string] | ordered; a track may appear in many collections |
| `artworkFile` | string | file name inside the collection folder |

Track IDs that don't exist (for example, still syncing) are kept but not shown.

## `Comments/<uuid>.json`

```json
{
  "id": "…",
  "timestamp": 21.5,
  "text": "bass too loud here",
  "createdAt": "2026-10-18T21:53:24Z",
  "author": "Michael"
}
```

`timestamp` is the position in the track in seconds.

## `notes.md`

Free-form UTF-8 text. An empty note is represented by the file not existing.

## `waveform.json`

```json
{ "version": 1, "peaks": [0, 12, 80, 255, …] }
```

Roughly 800 loudness values (RMS, normalized so the loudest is 255, with a gentle curve so quiet passages stay visible). It's derived from the audio and can be regenerated. It's stored so other devices can draw the waveform before the audio has downloaded.

## Sync and conflicts

The folder is meant to live in iCloud Drive, but any sync tool works. Data is split into many small files so that concurrent edits on two devices rarely collide. When iCloud does report a conflict on a JSON file, the version with the newest modification date wins and the others are discarded.
