# Notices

## This project

Copyright (C) 2026 g1010-mac-driver contributors.

The build script, documentation and illustrations in this repository are
licensed under the GNU General Public License, version 2 or (at your option)
any later version. See [LICENSE](LICENSE).

## Gutenprint

The macOS packages published in this repository's Releases contain software
built from **Gutenprint 5.3.5**:

- Project: https://gimp-print.sourceforge.io/
- Licence: GNU General Public License, version 2 or later
- Copyright: the Gutenprint authors (see the `AUTHORS` file in the source)

**Corresponding source.** Every release includes the unmodified upstream
source archive, `gutenprint-5.3.5.tar.xz`
(SHA-256 `f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70`).
The complete build recipe, including every change made to that source, is
`build-g1010-mac-driver.sh` in this repository. A copy of it is also
installed with the driver at `/Library/Printers/Gutenprint-G1010/doc/`.

**Changes made to Gutenprint:**

1. In `src/xml/papers/standard.xml`, three landscape envelope sizes are
   renamed to match their real dimensions:
   `w229h459_l → w459h229`, `w255h581_l → w581h255`,
   `w277h538_l → w538h277`.
2. The generated PPD gets these changes:
   - the absolute filter path is set;
   - `*1284DeviceID` and `*Product` lines are added for the G1010;
   - `*ShortNickName` is changed.
3. The CUPS NickName suffix is set at configure time to
   `" (for G1010) - CUPS+Gutenprint v"`.

## Trademarks

Canon and PIXMA are trademarks or registered trademarks of Canon Inc. This
project is not affiliated with, endorsed by, or supported by Canon Inc. The
names are used only to identify the printer this driver works with.

macOS is a trademark of Apple Inc.

## Not included

This repository doesn't contain or redistribute any Canon software. Canon's
Windows driver packages are Canon's copyrighted software and must not be
added to this repository.
