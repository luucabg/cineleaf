# Cineleaf project format

The version-2 `.cineleaf` package format is shared by Mac and Windows. Paths may differ between systems, so moving a project also requires moving or relinking its source media unless it is already in a portable location. Windows preserves fields it cannot yet animate visually, including keyframe curves, rather than discarding them.

A `.cineleaf` document is a directory package. The current format version is **2**.

```text
Example.cineleaf/
  project.json
  Media/                         # only after “Collect media inside project”
    <asset-id>-original-name.mov
```

Disposable caches and unsaved-project recovery are kept in the user’s Library outside the project package. A normal project does not silently copy large source media.

## `project.json`

The UTF-8, sorted-key JSON records:

- format version, project identity, dates, name, canvas, and rational frame rate;
- media metadata, last known paths, security-scoped bookmarks, optional project-relative paths, and optional proxy references;
- ordered tracks, clips, exact rational timeline/source time, trim, speed, reverse state, groups, links, roles, and enable/mute/lock state;
- transforms, crop, opacity, fades, audio level, color adjustments, effects, transitions, and scalar keyframes;
- text/subtitle style and timeline markers;
- the project’s most recently used export preferences.

User-named export presets are application preferences rather than project data.

A pause in black is represented as an intentional empty interval on the timeline; it does not add a synthetic media asset or change the format. Inserting one shifts later clips and markers and, when necessary, splits a clip while preserving its exact source-time mapping. Detached audio is a normal independent audio clip, so projects created with these tools remain valid version-2 projects on Mac and Windows.

## Save, autosave, and recovery

Before a save, the complete project is validated and encoded. `project.json` is written with Foundation’s atomic write option so an interrupted write does not intentionally replace the last good file with partial JSON.

Edits debounce autosave. A named project is saved back to its package. An unnamed project writes a recovery JSON file under Application Support; reopening or deliberately discarding recovery removes it.

## External and consolidated media

Imported assets normally keep a security-scoped bookmark, last known path, modification date, and non-authoritative cached metadata. If a file is missing, Cineleaf reports it and offers relinking.

“Collect media inside project” copies each source into `Media/` using an asset-ID-prefixed sanitized name, checks available disk space, writes through a temporary partial file, and updates the asset with both an absolute fallback and a project-relative path. On reopen, the relative path is preferred, so moving the entire `.cineleaf` package keeps collected media linked. Proxies remain disposable cache data and are never mistaken for export originals.

## Migration and compatibility

The decoder reads `formatVersion` before decoding the current model. Each migration advances exactly one version and the result is validated again. The v1→v2 migration adds advanced clip defaults and timeline markers without changing old edit decisions.

New optional media-reference fields decode safely from existing v2 documents. Unknown future versions are rejected without rewriting the package. A failed migration leaves the original bytes unchanged and exposes a user-facing error with local technical detail.
