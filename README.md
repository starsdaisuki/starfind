# StarFind

**English** · [简体中文](README.zh-CN.md)

StarFind is a lightweight file search panel for macOS. Press a global hotkey, type a
filename or a filter, then open the result, reveal it in Finder, or copy its path.

StarFind queries the macOS Spotlight index directly. It builds no file database of its own,
makes no network requests, and contains no telemetry.

## Features

- A Spotlight-style borderless panel raised by a global hotkey
- Everything-style queries: AND, OR, exclusion, wildcards, extension, type, size, date and directory filters
- Full-text file search through the Spotlight content index
- Quick Look preview, English / Chinese interface, launch at login and customisable hotkeys
- Configurable light / dark appearance, blur material, tint colour and selection colour
- Two cross-Space behaviours: follow the Space that summoned it, or show on all Spaces
- 153 built-in self-checks covering query parsing, ranking, settings, windowing and real Spotlight queries

## Requirements

- macOS 14 or later
- Swift 6 toolchain (the source uses Swift 5 language mode)

## Install from source

```bash
git clone https://github.com/starsdaisuki/starfind.git
cd starfind
make install
```

`make install` builds an ad-hoc signed app and installs it into `~/Applications/StarFind.app`.
The default hotkey is `⌥'`, changeable in Settings.

To build only:

```bash
make bundle
open build/StarFind.app
```

## Query syntax

### Basic operators

| Input | Meaning |
|---|---|
| `meeting notes` | The filename contains both words, in any order |
| `report\|summary` | Contains either word |
| `notes !draft` | Contains "notes" but excludes "draft" |
| `"Application Support"` | Quoted content is treated literally |
| `*.mp3` | With a wildcard present, matching applies to the whole filename |

### Filters

| Input | Meaning |
|---|---|
| `ext:jpg;png` | Extension list |
| `image:` `video:` `audio:` `doc:` `code:` `app:` | Type macros |
| `file:` `folder:` | Files only, or folders only |
| `size:>10mb` `size:2mb..10mb` | File size |
| `dm:today` `dm:7d` | Modification date; `dc:` for creation, `da:` for last opened |
| `dm:>2025-01-01` `dm:2025-01-01..2025-01-31` | ISO 8601 date comparison |
| `dir:~/Documents` | Restrict to a directory and its subdirectories |
| `content:minutes` | Search the Spotlight full-text index |

Combined examples:

```text
ext:md report !archive dm:7d
image: wallpaper size:>2mb
content:minutes dir:~/Documents
```

`|` applies only within a single token. StarFind does not implement Everything's
cross-token grouping expressions.

## Permissions and privacy

StarFind performs all searching and ranking locally. The source contains no network
requests, account system or telemetry SDK.

macOS filters Spotlight results by the calling app's TCC permissions. Without
authorisation, ordinary files in Desktop, Documents and Downloads may not appear. StarFind
requests access to these directories at launch and shows the status in Settings.

StarFind does not require Accessibility permission.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `↑` / `↓` | Move between results |
| `↩` | Run the default action |
| `⌘↩` | Reveal in Finder |
| `⌥↩` | Open With |
| `⌘C` | Copy the selected text if any, otherwise copy the result path |
| `Space` | Show or hide the preview |
| `Esc` | Close the panel |

## Development and verification

```bash
make test
```

Self-checks run in a throwaway `UserDefaults` suite and never modify your real settings
domain.

Three diagnostic commands are also available:

```bash
make query Q=report   # print the predicate, Spotlight results and ranking
make type Q=report    # simulate continuous typing
make panel Q=report   # end-to-end verification in the real panel
```

`make panel` genuinely shows the window and sends keyboard events, so it is not suitable
for a headless CI environment.

## Code layout

| Path | Responsibility |
|---|---|
| `SearchEngine.swift` | NSMetadataQuery lifecycle, ranking, filtering and throttling |
| `QuerySyntax.swift` | Query tokenization, filters and NSPredicate generation |
| `SearchViewModel.swift` | Results, selection state and file actions |
| `SearchPanel.swift` | NSPanel, hotkeys, focus and Space behaviour |
| `SearchView.swift` | SwiftUI result list and preview layout |
| `AppSettings.swift` | UserDefaults settings layer |
| `FileAccess.swift` | Permission checks for TCC-protected directories |
| `SelfTest.swift` | 153 self-checks and regression verification |

## Implementation notes

- [Spotlight tokenization of Chinese filenames](docs/spotlight-cjk-tokenization.md)
- [Spotlight results and TCC permissions](docs/spotlight-permission-filtering.md)
- [Panel notifications, throttling and keyboard events](docs/panel-layer-bugs.md)
- [Cross-Space window behaviour](docs/window-space-behavior.md)

These documents keep the reusable technical conclusions and verification methods, and
depend on no particular machine or user data.

## Known limitations

- The current build is ad-hoc signed; no Apple Developer ID signing or notarization yet.
- Spotlight filters out some results when access to TCC-protected directories is missing.
- Query capability is bounded by Spotlight's index coverage and tokenization rules.

## License

[MIT](LICENSE)
