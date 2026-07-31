# Spotlight results and TCC permissions

**English** · [简体中文](spotlight-permission-filtering.zh-CN.md)

Spotlight does not return every indexed path to an app. Results are filtered by the
caller's TCC permissions, which makes "missing permission" easy to mistake for "Spotlight
search is broken".

## Typical symptoms

- System apps and some user files can be found
- Ordinary files in Desktop, Documents or Downloads do not appear
- The same query returns different results from a terminal process and from an app launched
  through `open`

Running directly from a terminal may use the terminal app's permission context, whereas
`open StarFind.app` uses StarFind's own application identity. So "works on the command line,
broken once bundled" is not by itself evidence of an engine bug.

## Minimal reproduction

Create temporary test items in a protected directory, for example:

```text
~/Documents/starfind-fixture/sample.txt
~/Documents/starfind-fixture/sample.app
~/Downloads/starfind-fixture/sample.dmg
```

Run the same `NSMetadataQuery` under an authorised and an unauthorised app identity. Delete
the fixture afterwards, and never use real user files as regression samples.

## How StarFind handles it

`FileAccess.swift` wraps access to protected directories as `ProtectedFolder`:

1. Probe access to Desktop, Documents and Downloads narrowly at launch.
2. Let the system present the authorisation prompt while TCC is still undecided.
3. Show the current status of each directory in Settings.
4. Surface permissions as an actionable direction when results are obviously missing.

## Effect of code signing

An ad-hoc signed local development build may be treated as a different code instance after
repackaging, so an existing authorisation may need to be confirmed again. A proper release
should use a stable bundle identifier, Developer ID signing and notarization.

## Troubleshooting order

1. Confirm with `mdfind` that the file is indexed by Spotlight.
2. Reproduce using the actual `.app` identity, not just by running the executable from a terminal.
3. Check the "Files and Folders" authorisation in System Settings.
4. Compare authorised and unauthorised results against a synthetic fixture.
5. Only then investigate index coverage, the predicate, and UI result throttling.
