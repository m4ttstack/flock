# Third-party notices

Flock vendors and derives from the third-party software below, which
remains under its own license regardless of any license Flock itself
carries.

---

## Herdglass

<https://github.com/buldezir/Herdglass>

`Scripts/libghostty.sh` is adapted from Herdglass's script of the same name
(paths and the artifact's consuming build system differ; the vendoring
mechanics do not).

`Sources/FlockCore/Bridge/ControlBridge.swift` and
`Sources/FlockCore/Bridge/PaneControlChannel.swift` are ported from
Herdglass's `Sources/HerdrClient/ControlBridge.swift` and
`PaneControlChannel.swift` (adapted for flock's `--bridge <pane>` argv
shape, dependency-injected I/O for testability, and dropping the
scroll-forwarding path entirely per flock's control-transport ruling that
pane scrollback is shared viewport state, not per-client).

`Sources/Flock/Ghostty/GhosttyHost.swift`, `GhosttySession.swift`, and
`GhosttySurfaceView.swift` are ported from Herdglass's
`Sources/Herdglass/Ghostty/TerminalHost.swift`, `TerminalSession.swift`, and
`TerminalSurfaceView.swift`, with the config-loading half of
`Sources/Herdglass/GhosttyRuntime.swift` folded into `GhosttyHost` (the
window-chrome config reader in `GhosttyConfig.swift` is not ported).
`Sources/FlockCore/Ghostty/GhosttyThemeConfig.swift` and
`GhosttyKeyMods.swift` are the pure parts of the same port (theme-config text
generation and the key-modifier translation table), split out so they stay
reachable from `FlockCoreTests` without an app host. Adapted for flock's
own `Theme` system in place of mirroring a local Ghostty install, and for the
`--bridge` argv flock's surfaces run in place of a shell.

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

Upstream ancestor of the AppKit/libghostty glue in
`Sources/Flock/Ghostty/`, reached through Herdglass's own port of it
(Herdglass's file headers name GhosttyKit as their source; this tree ports
from Herdglass, not from GhosttyKit directly, but the lineage runs through
both).

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

---

## Inter

<https://github.com/rsms/inter>

The chrome typeface. Inter 4.1 static OTFs (Regular, Medium, SemiBold, Bold)
are bundled unmodified in `Sources/Flock/Resources/Fonts/`, with this
license alongside them as `Inter-LICENSE.txt`.

Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL

-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION AND CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
