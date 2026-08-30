# Cygwin API library

This directory records the license and provenance for the Cygwin runtime that is actually bundled with the John/`zip2john` Windows executables.

- Bundled DLL: `tools/extractors/cygwin1.dll`
- FileVersion/ProductVersion: `3.5.6` (confirmed from the local Windows `VersionInfo`)
- John build metadata: `Cygwin version: 3.5.6-1.x86_64, 2025-01-26`
- Role: Windows runtime dependency for the bundled John Jumbo and `zip2john` executables
- Source project: Cygwin, <https://cygwin.com/>
- Official licensing page: <https://cygwin.com/licensing.html>
- License: LGPL-3.0-or-later with the Cygwin Linking Exception

`LGPL-3.0.txt` is the standard GNU Lesser General Public License version 3 text. `CYGWIN_LINKING_EXCEPTION.txt` records the additional exception published by the Cygwin project.

The version evidence came from the bundled DLL's local `Get-Item ... | Select VersionInfo` result and the bundled John `--list=build-info` result. `cygcheck` was not present on PATH. A future binary release that redistributes this DLL must provide source availability corresponding to the exact Cygwin 3.5.6 binary, rather than pointing only to an unrelated latest release.
