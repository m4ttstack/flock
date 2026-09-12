# Third-party notices

Paddock vendors and derives from the third-party software below, which
remains under its own license regardless of any license Paddock itself
carries.

---

## Herdglass

<https://github.com/buldezir/Herdglass>

`Scripts/libghostty.sh` is adapted from Herdglass's script of the same name
(paths and the artifact's consuming build system differ; the vendoring
mechanics do not).

`Sources/PaddockCore/Bridge/ControlBridge.swift` and
`Sources/PaddockCore/Bridge/PaneControlChannel.swift` are ported from
Herdglass's `Sources/HerdrClient/ControlBridge.swift` and
`PaneControlChannel.swift` (adapted for paddock's `--bridge <pane>` argv
shape, dependency-injected I/O for testability, and dropping the
scroll-forwarding path entirely per paddock's control-transport ruling that
pane scrollback is shared viewport state, not per-client).

Business Source License 1.1. Licensor: Alexander Arutyunov. The Licensed
Work is (c) 2026 Alexander Arutyunov. Change Date 2030-08-21, Change License
MIT. Reused with the licensor's authorization.

---

## Ghostty / libghostty

<https://github.com/ghostty-org/ghostty>

Vendored as source at `Vendor/ghostty` and shipped in binary form as
`Vendor/GhosttyKit.xcframework`, built by `Scripts/libghostty.sh`.

MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## GhosttyKit

<https://github.com/briannadoubt/GhosttyKit>

Upstream ancestor of the AppKit/libghostty glue a later task ports into
Paddock; no code from it is in this tree yet.

MIT License

Copyright (c) 2026 Brianna Zamora

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
