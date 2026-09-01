RAR support provenance

The local tools\extractors\rar2john.exe is the RAR record extractor from the
official Openwall John the Ripper Windows CE package represented by release
tag v1.9.1-ce:

https://github.com/openwall/john-packages/releases/tag/v1.9.1-ce

The bundled John launcher reports build
1.9.0-jumbo-1+bleeding-126b2a4814 (2025-01-28), and the RAR extractor was
selected from the same observed package family. The extractor is used only on
the local archive to create an app-owned Runtime input for Hashcat or John.

License terms are the John the Ripper GPL-2.0-or-later terms and the stated
OpenSSL/unRAR linking exception in LICENSE and COPYING.txt in this directory.
