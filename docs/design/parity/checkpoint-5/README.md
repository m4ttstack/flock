# Checkpoint 5: attention toasts and the rail status dot

The complete v1 surface before the end-to-end suite. Task 28b added the top-right
attention stack and made the workspace rail's status legible; this is what both
looked like when Matt tried them by hand.

Produced at `2b5869a`, except `rail-before-tokyo-night.png`, which is the rail as it
stood at `7bc827e`. The fix round that followed (`9a7dae3`) moved no pixel, so these
are also what the app draws there. The nine
`chrome-*.png` and `attention-stack.png` come from the `PaddockChromeRender` scheme
rendering the real `MainWindow` offscreen at 900x560 from fixture data, with
`TEST_RUNNER_PADDOCK_CHROME_RENDER_DIR` set. `grid-status-dots.png` comes from the
same scheme at 1200pt. `live-window.png` is a window-id-scoped `screencapture` of the
running app.

| Capture | What it shows |
|---|---|
| `rail-before-tokyo-night.png` | The rail **before** this checkpoint, at BASE `7bc827e`: a 3x15pt indicator bar, and `herdr` (idle) carrying no mark at all. The reason the change was asked for. |
| `chrome-tokyo-night.png` | The same window **after**. Every row draws its aggregate status as an 8pt dot: filled yellow / red / teal for working / blocked / done, a hollow green ring for idle. The selected row (`paddock`) keeps its own status dot; selection is the row fill and the heavier name. |
| `chrome-*.png` (eight more) | The same rail in every theme the render suite covers, dark and light. Worth a look for the ring's contrast against a light chrome, and for Rose Pine Dawn (whose green role is a teal) and Kanagawa Lotus (whose working yellow is nearly brown). |
| `attention-stack.png` | Four panes wanting attention in workspaces the window is not showing: three cards plus a `+1 more` pill. Two `finished` (teal dot, plain border) over one `needs input` (red dot with a glow, red-tinted border), each with the `workspace › tab` breadcrumb and the jump arrow that becomes a dismiss `x` on hover. |
| `grid-status-dots.png` | The All Workspaces grid. The same `StatusDot` rule on workspace cards, tab handles and mini panes, so an idle or unknown entry now shows a ring rather than nothing. The accent bar still marks herdr's focused workspace and tab, beside the status dot rather than in place of it. |
| `live-window.png` | The real app against the `paddock-checkpoint-2b` scratch session. Every pane there is a plain shell, so every dot is the small centered `unknown` mark: what the rail looks like when there is genuinely nothing to report. |

The rename-editor and zoom-badge renders moved in this task too, but only because the
rail is in every window; they carry nothing about the rail or the toasts and are not
duplicated here. The current set lives in
`.superpowers/sdd/2026-09-10-paddock/task-28-renders/` (scratch, untracked).

Spec for what these should show: `docs/design/colors/minimal-spec.md` ("Status
marks") and `docs/design/PARITY.md` ("Status dots (herdr parity)").
