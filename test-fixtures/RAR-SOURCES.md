# RAR integration fixtures

These small RAR files are copied from the public `openwall/john-samples`
repository for local integration tests. They are test data only; the
application never downloads them at runtime.

| Local fixture | Upstream sample | Route exercised |
| --- | --- | --- |
| `rar5-hp0-password.rar` | `RAR5/rar5-hp0-password.rar` | RAR5, Hashcat mode 13000, John format `RAR5`, NanaZip `t` verification |
| `rar3-hp0.rar` | `RAR3/rar3-hp0.rar` | RAR3-hp, Hashcat mode 12500, John format `rar`, NanaZip `t` verification |
| `rar3-p1-comment.rar` | `RAR3/p1-comment.rar` | RAR3-p compressed, Hashcat mode 23800, NanaZip `t` verification |

Upstream source: <https://github.com/openwall/john-samples>

The RAR3-p uncompressed classifier and Hashcat mode 23700 adapter are kept in
the application, but this upstream sample set does not contain a valid
uncompressed record for a real fixture assertion. The test reports that case
as `NOT_VERIFIED` instead of treating a synthetic record as an integration
pass.
