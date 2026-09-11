# Harness marks

Badges for the new-pane launcher overlay (`PaneLauncherOverlay`), one per CLI
agent harness `HarnessRoster` can detect (`claude`, `codex` today).

## Outcome: monogram fallback for both

A non-interactive fetch of the official brand marks was attempted against
each vendor's own domain before falling back:

- `https://www.anthropic.com/brand` -> HTTP 404
- `https://www.anthropic.com/` -> HTTP 200, but no documented/discoverable
  logo asset path from a plain fetch (the brand page itself 404s, so there
  is no page to read an asset URL from)
- `https://openai.com/brand/` -> HTTP 403
- `https://openai.com/` -> HTTP 403 (blocks plain non-browser fetches
  entirely)

Neither vendor's official site yielded a fetchable SVG/PNG mark through a
plain, non-interactive request. Per the task brief, no hand-drawn
approximation was substituted; both harnesses render as a colored monogram
badge (`MonogramBadge` in `PaneLauncherOverlay.swift`) instead. No image
assets are bundled in this directory.

## Re-checking before public distribution

This is a personal tool; the monogram badges are a plain, generic stand-in,
not a rendering of either mark. If paddock is ever distributed beyond
personal use, re-fetch each vendor's current brand guidelines (they gate
usage, color, and clear-space rules) before adding a real asset here, and
treat any use as nominative use of a third-party mark, not an endorsement.

## Adding a fetched mark later

Drop the file in this directory (e.g. `claude-mark.svg`), reference it as
`markAssetName` on the matching `HarnessEntry` in `PaneLauncherOverlay.swift`,
and give it real bundle resource wiring (an asset catalog entry or a
`Bundle.module`-style resource, whichever the project's resource pipeline
uses at that time) -- `MonogramBadge` stays as the fallback path for any
roster entry that still has no bundled mark.
