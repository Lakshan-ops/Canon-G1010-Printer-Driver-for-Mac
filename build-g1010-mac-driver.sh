#!/bin/bash

set -euo pipefail
umask 022

# settings
GP_VER="5.3.5"
GP_SHA256="f5a9f47de28530b1ae2069cfbc647a9a641baeeabe809bb0ef2b3ec5b9668d70"
GP_SIZE="5667532"
GP_URLS=(
  "https://downloads.sourceforge.net/project/gimp-print/gutenprint-5.3/${GP_VER}/gutenprint-${GP_VER}.tar.xz"
  "https://ftp.osuosl.org/pub/blfs/conglomeration/gutenprint/gutenprint-${GP_VER}.tar.xz"
)

PREFIX="/Library/Printers/Gutenprint-G1010"            # driver home (isolated)
FILTER_NAME="rastertogutenprint.5.3"
FILTER_DEST="${PREFIX}/filter/${FILTER_NAME}"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
PPD_DEST="${PPD_DIR}/Canon-G1010-Gutenprint.ppd.gz"
QUEUE="Canon_G1010"
GP_DRIVER="bjc-PIXMA-G1000"                            # Gutenprint engine used
NICK_SUFFIX=" (for G1010) - CUPS+Gutenprint v"         # shown in macOS driver list

WORK="${G1010_WORKDIR:-$HOME/g1010-driver-build}"
SRC="${WORK}/src"
STAGE="${WORK}/stage"
OUT="${WORK}/out"
LOGS="${WORK}/logs"
PKGWORK="${WORK}/pkg"

PKG_ID="local.g1010-driver.gutenprint"                 # installer receipt id
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# helpers
say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32mOK\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %b\n' "$*" >&2; exit 1; }

# Hermetic environment: Apple tools only.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR \
      DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_FALLBACK_LIBRARY_PATH \
      LIBRARY_PATH CPATH C_INCLUDE_PATH STP_DATA_PATH STP_MODULE_PATH || true
export LC_ALL=C

preflight() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script must run on macOS."
  [[ $EUID -ne 0 ]] || die "Run this as your normal user (not with sudo). It will ask for your password when needed."

  if ! xcode-select -p >/dev/null 2>&1; then
    say "Apple's Command Line Tools are required. Opening the installer..."
    xcode-select --install || true
    die "Finish installing the Command Line Tools, then run this script again."
  fi

  SDK="$(xcrun --show-sdk-path 2>/dev/null)" || die "Could not locate the macOS SDK (try: xcode-select --install)."
  CC="$(xcrun -f clang)"
  [[ -f "${SDK}/usr/include/cups/raster.h" ]] || die "CUPS headers not found in the macOS SDK at ${SDK}."

  # Native architecture, even if this Terminal runs under Rosetta.
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then ARCH="arm64"; else ARCH="x86_64"; fi
  # Oldest macOS the result runs on (so the .pkg also works on other Macs).
  if [[ "$ARCH" == "arm64" ]]; then MIN_OS="11.0"; else MIN_OS="10.15"; fi
  NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  ok "macOS $(sw_vers -productVersion), ${ARCH}, SDK $(basename "$SDK")"
}

#  build
download_and_verify() {
  local tarball="${WORK}/gutenprint-${GP_VER}.tar.xz"
  mkdir -p "$WORK"
  if [[ -f "$tarball" ]] && [[ "$(shasum -a 256 "$tarball" | awk '{print $1}')" == "$GP_SHA256" ]]; then
    ok "Using previously verified download"
  else
    rm -f "$tarball" "${tarball}.part"
    local fetched=0 u
    for u in "${GP_URLS[@]}"; do
      say "Downloading Gutenprint ${GP_VER} from ${u%%/gutenprint-*}/..."
      if curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
              --retry 3 --connect-timeout 20 --silent --show-error \
              -o "${tarball}.part" "$u"; then
        fetched=1; break
      fi
    done
    [[ $fetched -eq 1 ]] || die "Download failed from all mirrors."
    mv "${tarball}.part" "$tarball"
  fi

  local size sum
  size="$(stat -f %z "$tarball")"
  sum="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  [[ "$size" == "$GP_SIZE" ]]  || { rm -f "$tarball"; die "Size mismatch (${size} != ${GP_SIZE}). File removed; not building."; }
  [[ "$sum"  == "$GP_SHA256" ]] || { rm -f "$tarball"; die "SHA-256 mismatch. File removed; not building."; }
  ok "SHA-256 verified: ${sum}"

  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -xf "$tarball" -C "$SRC" --strip-components 1
}

patch_source() {

  local xml="${SRC}/src/xml/papers/standard.xml" pair old new count
  [[ -f "$xml" ]] || die "Paper list not found in source: ${xml}"
  for pair in "w229h459_l:w459h229" "w255h581_l:w581h255" "w277h538_l:w538h277"; do
    old="${pair%%:*}"; new="${pair##*:}"
    count="$(grep -c "name=\"${old}\"" "$xml" || true)"
    if grep -q "name=\"${new}\"" "$xml"; then
      [[ "$count" == "0" ]] && continue          # already patched / fixed upstream
      die "Both ${old} and ${new} exist in the paper list; refusing to patch."
    fi
    case "$count" in
      0) continue ;;                             # size no longer defined upstream
      1) sed "s/name=\"${old}\"/name=\"${new}\"/" "$xml" > "${xml}.tmp" && mv "${xml}.tmp" "$xml"
         grep -q "name=\"${new}\"" "$xml" || die "Patching ${old} failed." ;;
      *) die "Unexpected: ${count} definitions of ${old}." ;;
    esac
  done
  ok "Patched Gutenprint paper list (landscape envelope size names)"
}

# Run CUPS's own PPD checker; any FAIL is fatal.
# $1 = plain-text PPD; further args are passed to cupstestppd (e.g. -I filters).
validate_ppd() {
  local ppd="$1" log="${LOGS}/cupstestppd.log"; shift
  if ! command -v cupstestppd >/dev/null 2>&1; then
    echo "    (cupstestppd not available on this macOS; skipping PPD validation)"
    return 0
  fi
  if cupstestppd -W translations "$@" "$ppd" > "$log" 2>&1; then
    if [[ $# -gt 0 ]]; then ok "cupstestppd: PASS (0 failures; filter checked after install)"
    else ok "cupstestppd: PASS (0 failures, including filter ownership/permissions)"; fi
  else
    grep -i "fail" "$log" | sed 's/^/    /' >&2
    return 1
  fi
}

make_cups_config() {
  # Use Apple's cups-config if present, otherwise a minimal stand-in.
  if [[ -x /usr/bin/cups-config ]]; then
    CUPS_CONFIG=/usr/bin/cups-config
  else
    CUPS_CONFIG="${WORK}/cups-config"
    cat > "$CUPS_CONFIG" <<'EOF'
#!/bin/sh
case " $* " in
  *" --version "*)    echo 2.3.4 ;;
  *" --libs "*)       echo -lcups ;;
  *" --serverbin "*)  echo /usr/libexec/cups ;;
  *" --datadir "*)    echo /usr/share/cups ;;
  *" --serverroot "*) echo /private/etc/cups ;;
  *)                  echo "" ;;
esac
EOF
    chmod 755 "$CUPS_CONFIG"
  fi
}

make_pkg_config_stub() {

  PKG_CONFIG_STUB="${WORK}/pkg-config"
  cat > "$PKG_CONFIG_STUB" <<'EOF'
#!/bin/sh
case "$1" in
  --version)                   echo 0.29.2; exit 0 ;;
  --atleast-pkgconfig-version) exit 0 ;;
esac
exit 1
EOF
  chmod 755 "$PKG_CONFIG_STUB"
}

compile() {
  mkdir -p "$LOGS" "$OUT"
  make_cups_config
  make_pkg_config_stub

  local cflags="-arch ${ARCH} -mmacosx-version-min=${MIN_OS} -O2 -isysroot ${SDK} -D_DARWIN_C_SOURCE -Wno-deprecated-declarations \
-Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types"

  say "Configuring (log: ${LOGS}/configure.log)..."
  ( cd "$SRC" && NO_PKGCONFIG_PATHS=1 PKG_CONFIG="$PKG_CONFIG_STUB" ./configure \
      --prefix="$PREFIX" --with-cups=/usr --with-cups-config="$CUPS_CONFIG" \
      --disable-nls --disable-libgutenprintui2 --without-gimp2 --without-readline \
      --disable-escputil --disable-test --disable-testpattern --disable-samples \
      --disable-cups-ppds --enable-static-genppd --enable-static --disable-shared \
      --with-modules=static --disable-dependency-tracking \
      --with-cups-nickname="$NICK_SUFFIX" \
      CC="$CC" CFLAGS="$cflags" LDFLAGS="-arch ${ARCH} -mmacosx-version-min=${MIN_OS} -isysroot ${SDK}" \
      PKG_CONFIG="$PKG_CONFIG_STUB" \
  ) > "${LOGS}/configure.log" 2>&1 || { tail -25 "${LOGS}/configure.log"; die "configure failed."; }
  ok "Configured"

  say "Compiling (log: ${LOGS}/make.log)..."
  ( cd "$SRC" &&
    make -j"$NCPU" -C include &&
    make -j"$NCPU" -C src/main &&
    make -j"$NCPU" -C src/xml &&
    make -j"$NCPU" -C src/cups "${FILTER_NAME}" "cups-genppd.5.3"
  ) > "${LOGS}/make.log" 2>&1 || { tail -30 "${LOGS}/make.log"; die "Compile failed."; }
  ok "Compiled"

  # Stage printer data files (XML) for install.
  rm -rf "$STAGE"
  ( cd "$SRC" && make -C src/xml install DESTDIR="$STAGE" ) > "${LOGS}/stage.log" 2>&1 \
    || die "Staging data files failed (see ${LOGS}/stage.log)."
  [[ -d "${STAGE}${PREFIX}/share/gutenprint/5.3/xml" ]] || die "Staged data directory missing."
  cp "${SRC}/src/cups/${FILTER_NAME}" "${OUT}/${FILTER_NAME}"
}

check_binary() {
  local bin="$1"
  file "$bin" | grep -q "$ARCH" || die "Filter was not built for ${ARCH}."
  # Only macOS system libraries allowed.
  local bad
  bad="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/|^/System/Library/' || true)"
  [[ -z "$bad" ]] || die "Filter links to non-system libraries:\n${bad}"
  local minos
  minos="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos" {print $2; exit}')"
  [[ -z "$minos" || "$minos" == "$MIN_OS" ]] || die "Filter targets macOS ${minos}, expected ${MIN_OS}."
  codesign --verify "$bin" 2>/dev/null || codesign --force --sign - "$bin"
  ok "Filter is native ${ARCH}, self-contained, and code-signed (ad hoc)"
}

make_ppd() {
  say "Generating the G1010 printer description (PPD)..."
  local tmp="${WORK}/ppdgen"
  rm -rf "$tmp"; mkdir -p "$tmp"
  STP_DATA_PATH="${SRC}/src/xml" "${SRC}/src/cups/cups-genppd.5.3" -l C -p "$tmp" "$GP_DRIVER" \
    > "${LOGS}/genppd.log" 2>&1 || die "PPD generation failed (see ${LOGS}/genppd.log)."
  local gen
  gen="$(ls "$tmp"/*.ppd.gz 2>/dev/null | head -1)"
  [[ -n "$gen" ]] || die "No PPD produced."

  gunzip -c "$gen" | awk -v filter="$FILTER_DEST" -v ver="$GP_VER" '
    /^\*Product:/       { print "*Product: \"(G1010 series)\""; next }
    /^\*ModelName:/     { print; print "*1284DeviceID: \"MFG:Canon;MDL:G1010 series;\""; next }
    /^\*ShortNickName:/ { print "*ShortNickName: \"Canon G1010 series\""; next }
    /^\*cupsFilter:/    { print "*cupsFilter: \"application/vnd.cups-raster 100 " filter "\""; next }
    { print }' > "${OUT}/Canon-G1010-Gutenprint.ppd"
  # NOTE: *ModelName and *NickName are left as generated on purpose: the filter
  # uses ModelName to select the print engine and checks the version in NickName.

  [[ "$(grep -c "^\*cupsFilter: \"application/vnd.cups-raster 100 ${FILTER_DEST}\"" "${OUT}/Canon-G1010-Gutenprint.ppd")" == "1" ]] \
    || die "PPD customization failed."
  grep -q '^\*StpDriverName:.*"bjc-PIXMA-G1000"' "${OUT}/Canon-G1010-Gutenprint.ppd" || die "PPD driver name missing."

  validate_ppd "${OUT}/Canon-G1010-Gutenprint.ppd" -I filters \
    || die "PPD failed validation (see ${LOGS}/cupstestppd.log)."
  gzip -9 -n -f "${OUT}/Canon-G1010-Gutenprint.ppd"
  ok "PPD ready"
}

# Make a small RGB test page in CUPS raster format and run it through the filter.
filter_selftest() {
  local filter="$1" ppd="$2" datapath="${3:-}"
  local t="${WORK}/selftest"; mkdir -p "$t"
  if [[ ! -x "${t}/mkraster" ]]; then
    cat > "${t}/mkraster.c" <<'EOF'
#include <cups/raster.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  cups_page_header2_t h; memset(&h, 0, sizeof h);
  int dpi = 600, w = dpi * 3, ht = dpi * 3;              /* 3x3 inch test patch */
  h.HWResolution[0] = h.HWResolution[1] = dpi;
  h.PageSize[0] = 595; h.PageSize[1] = 842;               /* A4 */
  h.ImagingBoundingBox[2] = 595; h.ImagingBoundingBox[3] = 842;
  h.cupsWidth = w; h.cupsHeight = ht; h.cupsBitsPerColor = 8; h.cupsBitsPerPixel = 24;
  h.cupsBytesPerLine = w * 3; h.cupsColorOrder = CUPS_ORDER_CHUNKED;
  h.cupsColorSpace = CUPS_CSPACE_RGB; h.NumCopies = 1; h.cupsRowFeed = 2;
  cups_raster_t *r = cupsRasterOpen(1, CUPS_RASTER_WRITE);
  if (!r || !cupsRasterWriteHeader2(r, &h)) return 1;
  unsigned char *line = malloc(h.cupsBytesPerLine);
  for (int y = 0; y < ht; y++) {
    for (int x = 0; x < w; x++) {
      unsigned char v = (((x / 300) + (y / 300)) % 2) ? 0 : 255;
      line[3*x] = v; line[3*x+1] = (unsigned char)((x * 255) / w); line[3*x+2] = v;
    }
    cupsRasterWritePixels(r, line, h.cupsBytesPerLine);
  }
  cupsRasterClose(r); free(line); return 0;
}
EOF
    "$CC" -arch "$ARCH" -isysroot "$SDK" -O2 -Wno-deprecated-declarations \
          -o "${t}/mkraster" "${t}/mkraster.c" -lcups > "${LOGS}/selftest-build.log" 2>&1 \
      || die "Could not build the self-test helper (see ${LOGS}/selftest-build.log)."
  fi
  local ppd_plain="${t}/test.ppd"
  gunzip -c "$ppd" > "$ppd_plain"
  "${t}/mkraster" > "${t}/page.ras"
  if [[ -n "$datapath" ]]; then
    STP_DATA_PATH="$datapath" PPD="$ppd_plain" "$filter" 1 "${USER:-user}" selftest 1 "" "${t}/page.ras" \
      > "${t}/page.prn" 2> "${t}/filter.log" || die "Filter self-test failed (see ${t}/filter.log)."
  else
    PPD="$ppd_plain" "$filter" 1 "${USER:-user}" selftest 1 "" "${t}/page.ras" \
      > "${t}/page.prn" 2> "${t}/filter.log" || die "Filter self-test failed (see ${t}/filter.log)."
  fi
  grep -q "^ERROR" "${t}/filter.log" && die "Filter reported errors (see ${t}/filter.log)."
  head -c 400 "${t}/page.prn" | grep -q "StartJob" || die "Filter output does not look like Canon print data."
  [[ "$(stat -f %z "${t}/page.prn")" -gt 100000 ]] || die "Filter output is unexpectedly small."
  ok "Test page rendered to Canon print data ($(( $(stat -f %z "${t}/page.prn") / 1024 )) KB)"
}

do_build() {
  preflight
  download_and_verify
  patch_source
  compile
  check_binary "${OUT}/${FILTER_NAME}"
  make_ppd
  say "Self-test before install..."
  filter_selftest "${OUT}/${FILTER_NAME}" "${OUT}/Canon-G1010-Gutenprint.ppd.gz" "${STAGE}${PREFIX}/share/gutenprint/5.3/xml"
  say "Build complete. Files are in ${OUT}"
}

#  install
do_install() {
  preflight
  [[ -f "${OUT}/${FILTER_NAME}" && -f "${OUT}/Canon-G1010-Gutenprint.ppd.gz" ]] || die "Nothing built yet. Run: $0 build"
  say "Installing into ${PREFIX} (your Mac password may be requested)..."
  sudo /bin/rm -rf "${PREFIX}"
  sudo /bin/mkdir -p "${PREFIX}/filter" "${PPD_DIR}"
  sudo /usr/bin/ditto "${STAGE}${PREFIX}/share" "${PREFIX}/share"
  sudo /usr/bin/install -m 755 "${OUT}/${FILTER_NAME}" "${FILTER_DEST}"
  sudo /usr/bin/install -m 644 "${OUT}/Canon-G1010-Gutenprint.ppd.gz" "${PPD_DEST}"
  # CUPS refuses filters that are not root-owned and write-protected.
  sudo /usr/sbin/chown -R root:wheel "${PREFIX}" "${PPD_DEST}"
  sudo /bin/chmod -R u=rwX,go=rX "${PREFIX}"
  sudo /usr/bin/xattr -r -d com.apple.quarantine "${PREFIX}" 2>/dev/null || true
  ok "Installed ${FILTER_DEST}"
  ok "Installed ${PPD_DEST}"

  say "Self-test of the installed driver..."
  filter_selftest "${FILTER_DEST}" "${PPD_DEST}"
  gunzip -c "${PPD_DEST}" > "${WORK}/installed-check.ppd"
  if ! validate_ppd "${WORK}/installed-check.ppd"; then
    say "Installed PPD failed validation; rolling back..."
    sudo /bin/rm -rf "${PREFIX}"; sudo /bin/rm -f "${PPD_DEST}"
    die "Install rolled back (see ${LOGS}/cupstestppd.log)."
  fi
}

# add queue
do_add_printer() {
  [[ -f "$PPD_DEST" ]] || die "Driver not installed yet. Run: $0 install"
  say "Looking for the G1010 on USB..."
  local uri
  uri="$(sudo /usr/sbin/lpinfo --include-schemes usb --timeout 20 -v 2>/dev/null | awk '$2 ~ /^usb:\/\/Canon\/G1010/ {print $2; exit}')"
  if [[ -z "$uri" ]]; then
    echo "    Printer not found. Make sure it is switched on and connected by USB, then run:"
    echo "      $0 add-printer"
    echo "    (Or add it yourself: System Settings > Printers & Scanners > Add Printer,"
    echo "     pick the G1010, and under 'Use' choose 'Canon PIXMA G1000 (for G1010) - CUPS+Gutenprint v${GP_VER}'.)"
    return 0
  fi
  ok "Found ${uri}"
  sudo /usr/sbin/lpadmin -p "$QUEUE" -D "Canon G1010" -L "USB" -E -v "$uri" -P "$PPD_DEST" \
       -o printer-is-shared=false -o PageSize=A4
  ok "Printer '${QUEUE}' added. Print any document normally, or from Terminal:"
  echo "      lp -d ${QUEUE} /path/to/some.pdf"
}

# package
write_pkg_scripts() {
  local d="$1"; mkdir -p "$d"

  # preinstall: remove any previous version for a clean upgrade.
  cat > "${d}/preinstall" <<EOF
#!/bin/bash
# Canon G1010 driver (Gutenprint ${GP_VER}) - preinstall
P="${PREFIX}"
if [ "\$P" = "/Library/Printers/Gutenprint-G1010" ] && [ -d "\$P" ]; then /bin/rm -rf "\$P"; fi
exit 0
EOF

  # postinstall: place the PPD, lock down permissions, add/refresh the queue.
  cat > "${d}/postinstall" <<EOF
#!/bin/bash
# Canon G1010 driver (Gutenprint ${GP_VER}) - postinstall (runs as root)
P="${PREFIX}"
PPD_DIR="${PPD_DIR}"
PPD_DEST="${PPD_DEST}"
QUEUE="${QUEUE}"
LOG=/var/log/g1010-driver-install.log
exec >>"\$LOG" 2>&1
echo "== \$(/bin/date) installing Gutenprint ${GP_VER} for Canon G1010"

/bin/mkdir -p "\$PPD_DIR" || exit 1
/usr/bin/install -o root -g wheel -m 644 "\$P/ppd/Canon-G1010-Gutenprint.ppd.gz" "\$PPD_DEST" || exit 1
/usr/sbin/chown -R root:wheel "\$P" || exit 1
/bin/chmod -R u=rwX,go=rX "\$P" || exit 1

if /usr/bin/lpstat -p "\$QUEUE" >/dev/null 2>&1; then
  # Upgrade: give the existing printer the new PPD.
  /usr/sbin/lpadmin -p "\$QUEUE" -P "\$PPD_DEST" && echo "refreshed queue \$QUEUE"
else
  uri=\$(/usr/sbin/lpinfo --include-schemes usb --timeout 20 -v 2>/dev/null | /usr/bin/awk '\$2 ~ /^usb:\/\/Canon\/G1010/ {print \$2; exit}')
  if [ -n "\$uri" ]; then
    /usr/sbin/lpadmin -p "\$QUEUE" -D "Canon G1010" -L "USB" -E -v "\$uri" -P "\$PPD_DEST" \
      -o printer-is-shared=false -o PageSize=A4 && echo "added queue \$QUEUE (\$uri)"
  else
    echo "printer not connected; add it later in System Settings > Printers & Scanners"
  fi
fi
exit 0
EOF
  chmod 755 "${d}/preinstall" "${d}/postinstall"
}

write_uninstaller() {
  cat > "$1" <<EOF
#!/bin/bash
# Removes the Canon G1010 driver (Gutenprint ${GP_VER}) installed by the .pkg.
# Usage: sudo ${PREFIX}/uninstall.sh
if [ "\$(/usr/bin/id -u)" != "0" ]; then exec /usr/bin/sudo "\$0" "\$@"; fi
/usr/bin/lpstat -p "${QUEUE}" >/dev/null 2>&1 && /usr/sbin/lpadmin -x "${QUEUE}" && echo "Removed printer ${QUEUE}"
/bin/rm -f "${PPD_DEST}"
/usr/sbin/pkgutil --forget "${PKG_ID}" >/dev/null 2>&1
/bin/rm -rf "${PREFIX}"
echo "Canon G1010 driver removed."
EOF
  chmod 755 "$1"
}

write_installer_resources() {
  local r="$1"; mkdir -p "$r"
  cp "${SRC}/COPYING" "${r}/license.txt"
  cat > "${r}/welcome.html" <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{font:13px -apple-system,Helvetica,sans-serif;line-height:1.45}
h2{font-size:15px;margin:0 0 8px}code{font-size:12px}
</style></head><body>
<h2>Canon PIXMA G1010 driver for macOS</h2>
<p>This installs an open-source driver built from <b>Gutenprint ${GP_VER}</b>
for the Canon PIXMA G1010 connected by USB. Canon does not provide a macOS
driver for this printer; this is not a Canon product.</p>
<p><b>What gets installed</b></p>
<ul>
<li><code>${PREFIX}</code> (driver, data files, uninstaller)</li>
<li><code>${PPD_DEST}</code></li>
</ul>
<p>If the printer is switched on and plugged in, it is added automatically as
<b>${QUEUE}</b>. Otherwise add it later in <i>System Settings &rsaquo; Printers
&amp; Scanners</i> and choose the driver
<b>Canon PIXMA G1000 (for G1010) - CUPS+Gutenprint v${GP_VER}</b>.</p>
</body></html>
EOF
  cat > "${r}/conclusion.html" <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{font:13px -apple-system,Helvetica,sans-serif;line-height:1.45}
</style></head><body>
<p><b>The driver is installed.</b></p>
<p>Print from any app and choose <b>${QUEUE}</b> (or add the G1010 in
<i>System Settings &rsaquo; Printers &amp; Scanners</i> if it was not plugged in).</p>
<p>To remove everything later, run in Terminal:<br>
<code>sudo ${PREFIX}/uninstall.sh</code></p>
<p>Install log: <code>/var/log/g1010-driver-install.log</code></p>
</body></html>
EOF
}

write_distribution() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Canon G1010 Driver (Gutenprint ${GP_VER})</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <license file="license.txt" mime-type="text/plain"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="true" hostArchitectures="${ARCH}"/>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <volume-check>
    <allowed-os-versions><os-version min="${MIN_OS}"/></allowed-os-versions>
  </volume-check>
  <choices-outline>
    <line choice="default"><line choice="${PKG_ID}"/></line>
  </choices-outline>
  <choice id="default"/>
  <choice id="${PKG_ID}" visible="false"><pkg-ref id="${PKG_ID}"/></choice>
  <pkg-ref id="${PKG_ID}" version="${GP_VER}" onConclusion="none">g1010-driver-component.pkg</pkg-ref>
</installer-gui-script>
EOF
}

verify_pkg() {
  local pkg="$1" x="${PKGWORK}/verify"
  rm -rf "$x"
  pkgutil --expand-full "$pkg" "$x" >/dev/null || die "Could not expand the built .pkg."
  local payload="${x}/g1010-driver-component.pkg/Payload"
  local scripts="${x}/g1010-driver-component.pkg/Scripts"
  [[ -x "${payload}/filter/${FILTER_NAME}" ]]               || die ".pkg is missing the filter."
  [[ -f "${payload}/ppd/Canon-G1010-Gutenprint.ppd.gz" ]]   || die ".pkg is missing the PPD."
  [[ -d "${payload}/share/gutenprint/5.3/xml" ]]            || die ".pkg is missing printer data."
  [[ -x "${payload}/uninstall.sh" ]]                        || die ".pkg is missing the uninstaller."
  [[ -x "${scripts}/preinstall" && -x "${scripts}/postinstall" ]] || die ".pkg is missing install scripts."
  cmp -s "${payload}/filter/${FILTER_NAME}" "${OUT}/${FILTER_NAME}" || die ".pkg filter differs from the tested build."
  # The filter inside the package must still render a page.
  filter_selftest "${payload}/filter/${FILTER_NAME}" "${payload}/ppd/Canon-G1010-Gutenprint.ppd.gz" \
                  "${payload}/share/gutenprint/5.3/xml"
  ok "Package contents verified"
}

do_package() {
  do_build
  say "Building the installer package..."
  local root="${PKGWORK}/root" scripts="${PKGWORK}/scripts" res="${PKGWORK}/resources"
  local final="${SCRIPT_DIR}/Canon-G1010-Driver-${GP_VER}-${ARCH}.pkg"
  rm -rf "$PKGWORK"; mkdir -p "${root}/filter" "${root}/ppd" "${root}/doc"

  # Payload (installed to ${PREFIX}).
  ditto "${STAGE}${PREFIX}/share" "${root}/share"
  install -m 755 "${OUT}/${FILTER_NAME}" "${root}/filter/${FILTER_NAME}"
  install -m 644 "${OUT}/Canon-G1010-Gutenprint.ppd.gz" "${root}/ppd/Canon-G1010-Gutenprint.ppd.gz"
  write_uninstaller "${root}/uninstall.sh"
  install -m 644 "${SRC}/COPYING" "${root}/doc/COPYING"
  install -m 644 "$SCRIPT_PATH" "${root}/doc/build-g1010-mac-driver.sh"
  cat > "${root}/doc/SOURCE.txt" <<EOF
Built from Gutenprint ${GP_VER} (GPL-2.0-or-later):
  https://sourceforge.net/projects/gimp-print/files/gutenprint-5.3/${GP_VER}/
  SHA-256 ${GP_SHA256}
Local change: three landscape envelope sizes renamed to match their dimensions
(w229h459_l->w459h229, w255h581_l->w581h255, w277h538_l->w538h277).
Full build recipe: build-g1010-mac-driver.sh in this folder.
EOF
  chmod -R u=rwX,go=rX "$root"
  xattr -cr "$root" 2>/dev/null || true

  write_pkg_scripts "$scripts"
  write_installer_resources "$res"
  write_distribution "${PKGWORK}/distribution.xml"

  COPYFILE_DISABLE=1 pkgbuild --root "$root" --install-location "$PREFIX" \
      --identifier "$PKG_ID" --version "$GP_VER" --scripts "$scripts" \
      --ownership recommended "${PKGWORK}/g1010-driver-component.pkg" \
      > "${LOGS}/pkgbuild.log" 2>&1 || die "pkgbuild failed (see ${LOGS}/pkgbuild.log)."

  local sign_args=()
  if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then sign_args=(--sign "$PKG_SIGN_IDENTITY" --timestamp); fi
  rm -f "$final"
  productbuild --distribution "${PKGWORK}/distribution.xml" --resources "$res" \
      --package-path "$PKGWORK" ${sign_args[@]+"${sign_args[@]}"} "$final" \
      > "${LOGS}/productbuild.log" 2>&1 || die "productbuild failed (see ${LOGS}/productbuild.log)."
  ok "Built ${final}"

  verify_pkg "$final"

  if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    pkgutil --check-signature "$final" | sed 's/^/    /'
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      say "Notarizing with Apple (this can take a few minutes)..."
      xcrun notarytool submit "$final" --keychain-profile "$NOTARY_PROFILE" --wait \
        > "${LOGS}/notarize.log" 2>&1 || die "Notarization failed (see ${LOGS}/notarize.log)."
      xcrun stapler staple "$final" > "${LOGS}/staple.log" 2>&1 || die "Stapling failed."
      ok "Notarized and stapled"
    fi
  else
    echo "    Package is unsigned. It installs normally on this Mac (it was built here)."
    echo "    On other Macs: double-click, then System Settings > Privacy & Security > Open Anyway."
  fi
  shasum -a 256 "$final" | awk '{print "    SHA-256 of package: " $1}'
  say "Done. Double-click the .pkg to install:"
  echo "      ${final}"
  open -R "$final" 2>/dev/null || true
}

# uninstall
do_uninstall() {
  say "Removing the G1010 driver (your Mac password may be requested)..."
  if lpstat -p "$QUEUE" >/dev/null 2>&1; then sudo /usr/sbin/lpadmin -x "$QUEUE"; ok "Removed printer queue ${QUEUE}"; fi
  [[ "$PREFIX" == "/Library/Printers/Gutenprint-G1010" ]] || die "Unexpected install path; refusing to delete."
  sudo /bin/rm -rf "$PREFIX"
  sudo /bin/rm -f "$PPD_DEST"
  pkgutil --pkg-info "$PKG_ID" >/dev/null 2>&1 && sudo /usr/sbin/pkgutil --forget "$PKG_ID" >/dev/null
  ok "Driver files removed. (Build folder ${WORK} can be deleted by hand.)"
}

#  main
case "${1:-all}" in
  build)        do_build ;;
  install)      do_install ;;
  add-printer)  do_add_printer ;;
  uninstall)    do_uninstall ;;
  package)      do_package ;;
  all)          do_build; do_install; do_add_printer ;;
  -h|--help)    awk 'NR>1 && /^set -euo/ {exit} NR>1' "$0" ;;
  *)            die "Unknown command '$1'. Use: build | install | add-printer | uninstall | package" ;;
esac
