# StarFind cross-Space window behaviour

**English** · [简体中文](window-space-behavior.zh-CN.md)

StarFind's search panel is an `NSPanel`. macOS Spaces, full-screen apps, Mission Control and
window collection behaviour together decide which desktop the panel appears on, and whether
it stays visible after switching desktops.

## Design goals

- The hotkey should work on the current Space
- The panel should not unexpectedly lose focus or teleport when Spaces change
- The user can choose Spotlight-style "belongs to the summoning desktop" behaviour
- Or let the same panel follow them across every Space

## State model

StarFind tracks these separately:

- Whether the user has explicitly asked for the panel
- Whether the panel is currently visible
- The current display generation
- The window identity before and after a Space switch

`window.isVisible` alone is not enough. During a Space transition, AppKit may briefly report
the old window state, and a late-arriving close event must not dismiss a panel that was just
summoned on the new Space.

## Spotlight mode

Spotlight mode is the default:

- The panel belongs to the Space that summoned it
- Switching Spaces ends the old panel session
- Pressing the hotkey again on a new Space creates a new display generation

This mode does not use `.canJoinAllSpaces`, avoiding a single window instance persisting
across several desktops.

## All-Spaces mode

This mode uses `.canJoinAllSpaces`:

- The same panel can appear on every Space
- A Space switch by itself does not end the query session
- Closing, opening a result, or pressing the hotkey again ends the panel session

## Applying a configuration change

Switching modes requires updating all of:

1. `NSPanel.collectionBehavior`
2. The current display intent
3. How the Space-change observer treats the old generation

Changing only the settings value without reapplying `collectionBehavior` leaves the
interface showing the new mode while the window still behaves as the old one.

## Regression verification

`SelfTest.testPanelVisibilityIntent` verifies the display intent and generation rules.
Manual verification should cover:

- Switching between ordinary Spaces
- Switching between an ordinary Space and a full-screen app
- Pressing the hotkey rapidly during the switch animation
- Where focus lands when opening a file, revealing in Finder, and closing with `Esc`
