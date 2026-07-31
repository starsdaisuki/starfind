# Panel notifications, throttling and keyboard events

**English** · [简体中文](panel-layer-bugs.zh-CN.md)

StarFind's engine tests cannot cover every UI failure. `NSMetadataQuery` batched
notifications, SwiftUI state updates, `NSPanel` focus and the macOS main menu combine into
problems that appear only in the real panel.

## The `make panel` diagnostic mode

```bash
make panel Q=report
```

It will:

1. Launch StarFind through `open`, using the real app identity.
2. Show the real search panel.
3. Feed text key events into the field editor one at a time.
4. Compare the panel's final state against a standalone engine query.

When verifying keyboard events, StarFind must be the active application and the panel must
own the key window.

## A post-completion update must not be dropped by throttling

`NSMetadataQuery` sends these notifications in batches:

- `NSMetadataQueryGatheringProgress`
- `NSMetadataQueryDidFinishGathering`
- `NSMetadataQueryDidUpdate`

The last two can arrive extremely close together. If the throttling logic simply `return`s
on the later update and no further notification follows, the interface stays permanently on
an intermediate batch.

StarFind's `emitDecision` has only two outcomes:

- Emit immediately
- Emit once more after the remaining throttle window

The deferred task carries the query generation number, so a task from an old query cannot
overwrite a newer one. After a query completes, the result count is also re-checked once.

## Text editing shortcuts need a main menu

When `NSApp.mainMenu == nil`, the search field still accepts text, but standard actions such
as `⌘A`, `⌘V`, `⌘X` and `⌘Z` may not dispatch correctly through the responder chain.
Configuring an `NSMenu` for the status bar item alone does not solve this.

StarFind creates a main menu matching AppKit's expectations and leaves the actions' target
as `nil`, letting the responder chain pick the field editor. `⌘C` needs special handling:
keep the system copy when there is a text selection in the field, otherwise copy the current
result path.

## Do not steal focus back when opening a result

Restoring the previous application when the panel is closed with `Esc` is reasonable. But
when opening a file or revealing it in Finder, activating the previous app after the target
window has appeared drags the user back to the original Space.

`PanelAction.restoresFocus` expresses the rule as a testable pure function:

- Close, copy path: restore the original app
- Open, reveal in Finder: do not restore; activate the target app that finally takes over

## Regression verification

`make test` checks the throttling decision, the main menu key equivalents and the focus
restoration rules. `make panel` covers the end-to-end path that necessarily depends on a
real window, field editor and keyboard events.
