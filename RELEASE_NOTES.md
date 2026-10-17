## Canon PIXMA G1010 driver for macOS: Gutenprint 5.3.5

**Install:** download `Canon-G1010-Driver-5.3.5-arm64.pkg`, double-click it,
then click **Continue → Agree → Install**. Requires an Apple silicon Mac
(M1 or later) running macOS 11 or newer. See the
[step-by-step guide](https://github.com/OWNER_REPO#readme).

The package isn't signed with an Apple Developer ID. If macOS blocks it, go to
**System Settings → Privacy & Security → Open Anyway**.

### Files

| File | What it is |
|---|---|
| `Canon-G1010-Driver-5.3.5-arm64.pkg` | The installer |
| `gutenprint-5.3.5.tar.xz` | The unmodified Gutenprint source this was built from (GPL) |
| `SHA256SUMS.txt` | Checksums. Verify with `shasum -a 256 -c SHA256SUMS.txt` |

This release was built by GitHub Actions from the tagged commit, using
`build-g1010-mac-driver.sh package`.

*Not affiliated with Canon. Gutenprint's Canon G-series support is experimental.*
