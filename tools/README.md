# Local offline recovery tools

This directory contains only the local command-line dependencies used by the Windows application. The application never downloads, updates, or contacts a service for these tools.

The runtime tree is intentionally staged rather than carrying the upstream archives:

- `hashcat\hashcat.exe`, `hashcat\modules\module_00000.dll`, `module_11600.dll`, `module_13600.dll`, and the complete `OpenCL` source directory are the Windows Hashcat 7.1.2 OpenCL runtime needed by the implemented mode 11600/13600 routes. The small kernel/tuning data files are retained for the local backend.
- `extractors\zip2john.exe` plus the bundled Cygwin/JtR launcher and CPU variants are the local ZIP extraction chain. `extractors\john.exe` is the preferred John Jumbo launcher for CPU bulk recovery; it is given an app-owned config, pot, session, status, and wordlist under `%LOCALAPPDATA%\ArchivePasswordRecovery\Runtime\<JobId>\<RunId>`. The JtR CPU variants are retained because the launcher dispatches through them on this Windows build.
- `extractors\7z2hashcat.exe` is the local Windows extractor used to produce a Hashcat mode 11600 record for supported 7z AES archives. It does not require a separately installed Perl runtime.
- `licenses\hashcat` contains the Hashcat and bundled third-party license notices; `licenses\JtR` contains the JtR notices used by the retained ZIP extractor; `licenses\7z2hashcat` contains the upstream notice, license, and provenance record for the local 7z extractor.
- `Build-BuiltinDictionaries.ps1` remains a development-time dictionary builder and is not invoked by the application at runtime.

The original upstream archives and unused Hashcat/JtR modules, examples, rules, masks, Linux modules, and unrelated extractors are not part of the publish tree. No auto-download, telemetry, online hash lookup, crash upload, remote execution, or cloud recovery behavior should be added here.

License status is explicit: Hashcat, JtR, and 7z2hashcat notice files are present in `licenses`. The local `extractors\7z2hashcat.exe` was directly byte-compared with the official upstream `7z2hashcat64-2.0.exe` Windows release asset; the comparison is recorded in `licenses\7z2hashcat\SOURCE`.

The present GPU routes are deliberately limited to ZIP WinZip AES records accepted by Hashcat mode 13600 and 7z AES records accepted by Hashcat mode 11600. For CPU bulk recovery, ZIP WinZip AES (`$zip2$`), ZIP ZipCrypto (`$pkzip$`), and 7z AES (`$7z$`) are passed through the local extractor and one long-lived John Jumbo process when the bundled build accepts the record; a John result is never trusted without one final local NanaZip `7z t`. Quick/tiny candidates and unsupported strategies/formats stay on the CPU/NanaZip fallback path. No John artifact is written to the project tree, user Home, or a global `john.pot`/`john.log`.
