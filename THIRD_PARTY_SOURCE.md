# Third-Party Source Correspondence

This repository intentionally does not add large upstream source archives to Git history. The binary release policy below keeps every bundled binary tied to its exact observed version or revision and requires the corresponding source to be made available with any future binary release.

## John the Ripper Jumbo

- Bundled build: `1.9.0-jumbo-1+bleeding-126b2a4814`, built `2025-01-28 23:51:55 +0100`.
- Binary origin: the Cygwin 64-bit Openwall/John Jumbo build represented by `tools/extractors/john.exe` and its sibling CPU variants; the version, build mode, and revision are reported by `john.exe --list=build-info`.
- Upstream repository: <https://github.com/openwall/john>
- Release baseline: `1.9.0-jumbo-1`; bundled build revision: `126b2a4814`.
- License: GPL-2.0-or-later with the OpenSSL/unRAR linking exception; the formal texts remain in `tools/licenses/JtR/LICENSE` and `tools/licenses/JtR/COPYING.txt`.
- Future release policy: a GitHub Release that distributes these John binaries must also provide an exact corresponding source archive for revision `126b2a4814` and must not substitute the latest John source.

## Cygwin

- Bundled DLL: `tools/extractors/cygwin1.dll`.
- Exact observed version: FileVersion/ProductVersion `3.5.6`; the John build reports package `3.5.6-1.x86_64`.
- Source project and licensing: Cygwin, <https://cygwin.com/>; official licensing terms at <https://cygwin.com/licensing.html>.
- License: LGPL-3.0-or-later with the Cygwin Linking Exception; retained in `third_party/licenses/cygwin/`.
- Future release policy: a binary release that redistributes this DLL must provide source availability corresponding to the exact `3.5.6` binary and its licensing terms, not merely a link to an unrelated latest version.

## Hashcat

- Bundled version: `7.1.2` (`tools/hashcat/hashcat.exe` and the required OpenCL/modules tree).
- Upstream source project: <https://github.com/hashcat/hashcat>
- License: MIT, with the bundled accompanying notices under `tools/licenses/hashcat/`.
- Future release policy: attach or otherwise make available the source corresponding to the exact Hashcat `7.1.2` binary tree used by the release; do not replace it with a newer version while retaining this version label.

## 7z2hashcat

- Bundled version: upstream Windows 64-bit release `2.0` (`7z2hashcat64-2.0.exe`), copied as `tools/extractors/7z2hashcat.exe`.
- Upstream source and release: <https://github.com/philsmd/7z2hashcat>, release <https://github.com/philsmd/7z2hashcat/releases/tag/2.0>.
- License: Public Domain with required attribution and disclaimer; see `tools/licenses/7z2hashcat/`.
- The exact release asset and local executable correspondence are recorded in `tools/licenses/7z2hashcat/SOURCE`.

## SecLists dictionary material

- Bundled source snapshot: official SecLists master snapshot downloaded on `2026-08-27`, recorded as `SecLists-official-master-2026-08-27` in `resources/dictionary-manifest.json`.
- Upstream source: <https://gitlab.com/pentesting-tools/SecLists>; the manifest records each official raw source URL and the six included files.
- License: MIT; see `resources/licenses/SecLists-LICENSE.txt`.
- The built-in dictionaries also contain the explicitly recorded `project-curated-offline-v1` material in the same manifest; that project-curated material is part of this repository's original data selection.
