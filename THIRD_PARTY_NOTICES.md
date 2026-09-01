# Third-Party Notices

This repository bundles the components listed below because they are required by the documented local recovery paths. Their included license and notice files remain in the locations shown here. NanaZip / 7-Zip is invoked only as a locally installed prerequisite and is not bundled by this repository.

| Component | Bundled version | License / status | Repository location | Purpose |
| --- | --- | --- | --- | --- |
| Hashcat | 7.1.2 | MIT; see `tools/licenses/hashcat/license.txt` | `tools/hashcat/` | Local OpenCL GPU backend for supported ZIP AES, 7z AES, RAR3-hp, RAR5, and RAR3-p routes. |
| John the Ripper Jumbo | 1.9.0-jumbo-1+bleeding-126b2a4814 (build dated 2025-01-28) | GPL-2.0-or-later with the stated OpenSSL / unRAR linking exception; see `tools/licenses/JtR/LICENSE` and `COPYING.txt` | `tools/extractors/john*.exe`, `tools/extractors/zip2john.exe`, `tools/extractors/rar2john.exe` | Local CPU bulk backend plus ZIP/RAR record extraction. |
| Cygwin API library and runtime libraries | `cygwin1.dll` 3.5.6 (John build reports package `3.5.6-1.x86_64`) | LGPL-3.0-or-later with Cygwin Linking Exception; see `third_party/licenses/cygwin/` | `tools/extractors/cyg*.dll` | Windows runtime dependency for the bundled John / `zip2john` executables. |
| 7z2hashcat | 2.0 (Windows 64-bit release) | Public Domain; attribution and disclaimer retained in `tools/licenses/7z2hashcat/` | `tools/extractors/7z2hashcat.exe` | Local extraction of supported 7z AES records for Hashcat. |
| SecLists dictionary material | Version not separately recorded | MIT; see `resources/licenses/SecLists-LICENSE.txt` | `resources/dictionaries/*.txt.gz` | Bundled wordlists used by the built-in recovery levels. |

## Hashcat accompanying notices

The bundled Hashcat runtime also retains the following license texts under `tools/licenses/hashcat/`. Where the upstream component version is not stated in the retained text, it is recorded as not separately identified rather than inferred.

| Component | Bundled version | License | Notice file |
| --- | --- | --- | --- |
| LZMA SDK | Not separately identified | Public Domain | `LZMA_SDK_LICENSE.txt` |
| miniz | Not separately identified | MIT | `MINIZ_LICENSE.txt` |
| OpenCL Headers | Not separately identified | Apache-2.0 | `OPENCL_HEADERS_LICENSE.txt` |
| SSE2NEON | Not separately identified | MIT | `SSE2NEON_LICENSE.txt` |
| UnRAR | Not separately identified | UnRAR license | `UNRAR_LICENSE.txt` |
| xxHash | Not separately identified | BSD-2-Clause | `XXHASH_LICENSE.txt` |
| zlib | Not separately identified | zlib License | `ZLIB_LICENSE.txt` |

Project homepages:

- Hashcat: <https://hashcat.net/hashcat/>
- John the Ripper: <https://www.openwall.com/john/>
- Cygwin: <https://www.cygwin.com/>
- 7z2hashcat: <https://github.com/philsmd/7z2hashcat>
- SecLists: <https://github.com/danielmiessler/SecLists>

This file records bundled-component notices only. It does not grant a license for this repository's original source code; that code is licensed separately under the root `LICENSE` file.
