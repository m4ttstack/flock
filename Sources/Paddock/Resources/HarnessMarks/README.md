# Harness marks

Badges for the new-pane launcher overlay (`PaneLauncherOverlay`), one per CLI
agent harness `HarnessRoster` can detect (`claude`, `codex` today).

## The files here are the source of record, not the asset

Nothing in this directory is loaded at runtime. Each mark is a single SVG
path, and that path's `d` attribute is compiled into `HarnessMark` in
`Sources/PaddockCore/Marks/`, where `VectorMarkPath` decodes it to a `CGPath`
and the launcher fills it. Bundled images were not used: an image resolved by
name resolves differently in the app bundle and in the offscreen chrome-render
bundle, so a mark could pass its render test and still be blank in the app.
Compiled path data has no lookup to fail.

`HarnessMarkTests.testTheCompiledPathDataMatchesTheSourceSVGs` fails if the
compiled data and the file below it ever disagree, so these files stay the
record of where each mark came from.

`VectorMarkPath` reads absolute `M`, `L`, `H`, `V`, `C` and `Z` only, and
returns nothing at all for anything else. A mark it cannot read falls back to
the monogram badge rather than drawing a partial glyph, which is also what a
roster entry with no mark at all gets.

## claude.svg

- Source: `https://assets-proxy.anthropic.com/claude-ai/v2/assets/v1/cd02a42d9-Vq_H3mgS.svg`,
  the SVG claude.ai serves as its own site icon.
- 248x248 viewBox, one path, fill `#D97757`.
- Anthropic publishes no brand page (`anthropic.com/brand` 404s), so there are
  no stated usage terms, and there is no separate monochrome variant.

## codex.svg

- Source: OpenAI's official brand zip from `https://openai.com/brand/`, the
  `OAI_OpenAI-Blossom_White.svg` variant.
- 716x716 viewBox, one path, white fill.
- The White variant rather than the Black one: paddock's chrome is dark in
  most themes, where black would be invisible.
- Codex has no distinct mark of its own; its favicon is the generic OpenAI
  one, which is what this is.

### OpenAI's stated terms for the Blossom

1. Do not add colors to it.
2. Do not use it as primary branding.
3. Do not place it over a busy image.
4. Give it open space.

How the launcher satisfies each: it is drawn in the file's own white, never
tinted or themed; it badges a button labelled with the binary name, which is
the harness's name and not paddock's branding; it sits on a plain black disc,
which is also what makes the white readable on paddock's light themes; and
`ChromeMetrics.Launcher.markInset` holds it clear of the disc's edge.

The Claude mark carries its own color and is left as it is, on the same disc.

## Adding a harness

Add the entry to `HarnessRoster.known`. A `mark:` is optional -- without one
the entry renders as a colored monogram badge, which is a supported state and
not a placeholder. With one, drop the vendor's SVG here, record its source and
terms in this file the way the two above are recorded, and add the path data
to `HarnessMark`.

Any use of a third-party mark here is nominative use, not an endorsement. If
paddock is ever distributed beyond personal use, re-read each vendor's current
brand guidelines first: they gate usage, color, and clear-space rules, and
they change.
