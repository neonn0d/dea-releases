#!/bin/sh
# Install Dea on macOS or Linux:
#
#   curl -fsSL https://dea.dardanica.app/install | sh
#
# It finds the latest release, downloads the build for this computer, checks it
# against the SHA-256 the release publishes, and installs it:
#   macOS            Dea.app into /Applications (or ~/Applications)
#   Arch Linux       the pacman package (asks for your password)
#   Debian / Ubuntu  the .deb package (asks for your password)
#   other Linux      an AppImage in ~/.local/bin, with a menu entry
#
# Options (environment variables):
#   DEA_VERSION=0.9.9    install that version instead of the latest
#   DEA_KIND=appimage    on Linux, force appimage, deb or pacman
#   DEA_DRY_RUN=1        say what would be done, and do nothing
#   NO_COLOR=1           plain text, no figure
set -eu

REPO="neonn0d/dea-releases"
have() { command -v "$1" >/dev/null 2>&1; }

# ---- what is printed ----
# In a terminal: the Dea figure on the left, and each step beside it as it
# finishes. Anywhere else (a pipe, a log, NO_COLOR, a narrow window): one plain
# line per step.
FANCY=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  width=$(stty size 2>/dev/null </dev/tty | awk '{print $2}') || width=""
  [ "${width:-80}" -ge 64 ] && FANCY=1
fi
if [ "$FANCY" = 1 ]; then B=$(printf '\033[1m'); D=$(printf '\033[2m'); G=$(printf '\033[32m'); E=$(printf '\033[31m'); R=$(printf '\033[0m'); else B=""; D=""; G=""; E=""; R=""; fi
TOTAL=14 # rows of the figure
COL=24   # where the text starts
ROW=3    # the next free row beside the figure

# Write text on a row beside the figure (the cursor rests on the line under it).
put() { up=$((TOTAL - $1 + 1)); printf '\033[%dA\033[%dG\033[K%s\033[%dB\r' "$up" "$COL" "$2" "$up"; }
banner() {
  [ "$FANCY" = 1 ] || { printf 'Dea: a browser your coding agent can use\n'; return 0; }
  printf '\n'
  cat <<'ART_END'
         ⣰⣶⡀
         ⢻⣿⣧
         ⣠⣿⣿⣤
        ⢸⣿⡿⣿⣿⡇
        ⣿⢙⡽⣿⣿⡇
       ⣼⠏⣿⣿⣿⣿⣿
      ⡼⠋⢸⣿⣿⣿⡟⡻
    ⢀⣰⠇ ⢸⣿⡿⣿⡇⡟
    ⣩⢣  ⢸⣿⣇⣿⡇⠁
   ⠈⡙⡎  ⢸⣿⣸⣿⣿
   ⠐⠃   ⢸⡏⣿⣿⣿
        ⠈⢹⡇⣿⣿⡄
        ⢀⣿⢇⣿⡿⣧
       ⠠⠾⠿⠾⠿⠿⠙⠂
ART_END
  put 4 "${B}Dea${R}${D}.${R}"
  put 5 "${D}A browser your coding agent can use${R}"
  ROW=7
}
# A finished step: ok "Title" "detail".
ok() {
  if [ "$FANCY" = 1 ] && [ "$ROW" -le "$TOTAL" ]; then put "$ROW" "${G}✓${R} $1${2:+  $D$2$R}"; ROW=$((ROW + 1)); else printf '%s%s\n' "$1" "${2:+: $2}"; fi
}
# A step still running; the next ok or progress line replaces it.
doing() { if [ "$FANCY" = 1 ] && [ "$ROW" -le "$TOTAL" ]; then put "$ROW" "${D}$1${R}"; else printf '%s\n' "$1"; fi; }
fail() {
  if [ "$FANCY" = 1 ] && [ "$ROW" -le "$TOTAL" ]; then put "$ROW" "${E}✗${R} Not installed"; printf '\n  %s\n' "$*" >&2; else printf 'Dea install: %s\n' "$*" >&2; fi
  exit 1
}

have curl || { printf 'Dea install: curl is needed.\n' >&2; exit 1; }
os=$(uname -s)
machine=$(uname -m)
banner

# ---- which release file suits this computer ----
case "$os" in
  Darwin)
    # A terminal running under Rosetta reports x86_64 on an Apple silicon Mac.
    if [ "$machine" = "arm64" ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then suffix="-arm64.zip"; where="macOS, Apple silicon"; else suffix="-x64.zip"; where="macOS, Intel"; fi
    kind="mac"
    ;;
  Linux)
    [ "$machine" = "x86_64" ] || fail "Dea for Linux is built for x86_64 only; this computer is $machine."
    kind="${DEA_KIND:-}"
    if [ -z "$kind" ]; then
      if have pacman; then kind="pacman"; elif have apt-get; then kind="deb"; else kind="appimage"; fi
    fi
    case "$kind" in
      pacman) suffix="-x86_64.pkg.tar.xz"; where="Linux, pacman package" ;;
      deb) suffix="-amd64.deb"; where="Linux, .deb package" ;;
      appimage) suffix="-x86_64.AppImage"; where="Linux, AppImage" ;;
      *) fail "DEA_KIND must be appimage, deb or pacman." ;;
    esac
    ;;
  *) fail "This script installs Dea on macOS and Linux. For Windows, download the installer from https://github.com/$REPO/releases" ;;
esac
ok "$where"

# ---- the release, from GitHub: file names, sizes, checksums, addresses ----
if [ -n "${DEA_VERSION:-}" ]; then api="https://api.github.com/repos/$REPO/releases/tags/v${DEA_VERSION#v}"; else api="https://api.github.com/repos/$REPO/releases/latest"; fi
doing "Looking for the release ..."
release=$(curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 -H "Accept: application/vnd.github+json" "$api" 2>/dev/null) || fail "Could not read the release from GitHub. Check your connection, or download from https://github.com/$REPO/releases"

# One line per file: name, size, checksum, address.
files=$(printf '%s\n' "$release" | awk '
  /"name": *"Dea-/ { name = $0; sub(/.*"name": *"/, "", name); sub(/".*/, "", name) }
  /"size": *[0-9]/ { size = $0; sub(/.*"size": */, "", size); sub(/[^0-9].*/, "", size) }
  /"digest": *"sha256:/ { digest = $0; sub(/.*"sha256:/, "", digest); sub(/".*/, "", digest) }
  /"browser_download_url":/ { url = $0; sub(/.*"browser_download_url": *"/, "", url); sub(/".*/, "", url); if (name != "") print name, size + 0, (digest == "" ? "-" : digest), url; name = ""; digest = ""; size = "" }
')
# The name must be exactly Dea-<version><suffix>: "-x64.zip" alone would also
# match the Windows zip.
line=$(printf '%s\n' "$files" | awk -v s="$suffix" '{ v = $1; if (substr(v, 1, 4) != "Dea-" || length(v) <= length(s) + 4) next; if (substr(v, length(v) - length(s) + 1) != s) next; mid = substr(v, 5, length(v) - length(s) - 4); if (mid ~ /^[0-9][0-9.]*$/) { print; exit } }')
[ -n "$line" ] || fail "This release has no ${suffix#-} build. See https://github.com/$REPO/releases"
name=$(printf '%s' "$line" | awk '{print $1}')
size=$(printf '%s' "$line" | awk '{print $2}')
sum=$(printf '%s' "$line" | awk '{print $3}')
url=$(printf '%s' "$line" | awk '{print $4}')
version=${name#Dea-}; version=${version%"$suffix"}
printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' || fail "The release publishes no checksum for $name, so it will not be installed."
case "$url" in https://github.com/"$REPO"/releases/download/*) ;; *) fail "Unexpected download address: $url" ;; esac
mb=$(( (size + 524288) / 1048576 ))
if [ -n "${DEA_VERSION:-}" ]; then ok "Dea $version"; else ok "Dea $version" "latest release"; fi

if [ -n "${DEA_DRY_RUN:-}" ]; then
  ok "Dry run" "would download $name, $mb MB"
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dea-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

# ---- download, with a bar that follows the file as it grows ----
if [ "$FANCY" = 1 ]; then
  curl -fsL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp/$name" "$url" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    got_bytes=0; [ -f "$tmp/$name" ] && got_bytes=$(wc -c < "$tmp/$name")
    got_bytes=$((got_bytes + 0))
    n=0; [ "$size" -gt 0 ] && n=$((got_bytes * 20 / size)); [ "$n" -gt 20 ] && n=20
    bar=$(printf '%*s' "$n" '' | sed 's/ /━/g'); rest=$(printf '%*s' "$((20 - n))" '' | sed 's/ /━/g')
    put "$ROW" "${D}↓${R} ${B}${bar}${R}${D}${rest}  $((got_bytes / 1048576)) of $mb MB${R}"
    sleep 0.2
  done
  wait "$pid" || fail "The download failed. Try again."
else
  printf 'Downloading %s (%s MB) ...\n' "$name" "$mb"
  curl -fsL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp/$name" "$url" || fail "The download failed. Try again."
fi
ok "Downloaded" "$mb MB"

if have sha256sum; then got=$(sha256sum "$tmp/$name" | awk '{print $1}'); elif have shasum; then got=$(shasum -a 256 "$tmp/$name" | awk '{print $1}'); else fail "Neither sha256sum nor shasum is available to check the download."; fi
[ "$got" = "$sum" ] || fail "The download does not match the release's checksum, so it was not installed. Try again."
ok "Checksum matches"

# sudo for a package install; plain when already root. The password question
# appears under the figure.
as_root() { if [ "$(id -u)" = "0" ]; then "$@"; elif have sudo; then sudo "$@"; else fail "This step needs root. Run it yourself: $*"; fi; }

case "$kind" in
  mac)
    if pgrep -x Dea >/dev/null 2>&1; then fail "Dea is running. Quit it, then run this again."; fi
    # ditto keeps the app bundle intact (links, permissions); unzip can break it.
    ditto -x -k "$tmp/$name" "$tmp/app" || fail "Could not unpack $name."
    app=$(find "$tmp/app" -maxdepth 1 -name '*.app' -type d | head -n 1)
    [ -n "$app" ] || fail "No app found inside $name."
    dest="/Applications"
    if [ ! -w "$dest" ]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
    target="$dest/$(basename "$app")"
    rm -rf "$target"
    mv "$app" "$target"
    # A file fetched by curl is not marked as downloaded from the internet, so
    # macOS opens it without the unsigned-app block. Clear the mark anyway, in
    # case this file passed through something that set it.
    xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
    ok "Installed" "$target"
    ;;
  pacman)
    doing "Installing the package (your password may be asked) ..."
    as_root pacman -U --noconfirm "$tmp/$name" >"$tmp/log" 2>&1 || { cat "$tmp/log" >&2; fail "pacman could not install the package."; }
    ok "Installed" "pacman package"
    ;;
  deb)
    doing "Installing the package (your password may be asked) ..."
    chmod 755 "$tmp"; chmod 644 "$tmp/$name"
    as_root apt-get install -y "$tmp/$name" >"$tmp/log" 2>&1 || { cat "$tmp/log" >&2; fail "apt could not install the package."; }
    ok "Installed" ".deb package"
    ;;
  appimage)
    bin="${DEA_BIN_DIR:-$HOME/.local/bin}"
    data="${XDG_DATA_HOME:-$HOME/.local/share}"
    mkdir -p "$bin" "$data/applications"
    mv "$tmp/$name" "$bin/dea"
    chmod +x "$bin/dea"
    cat > "$data/applications/dea.desktop" <<EOF
[Desktop Entry]
Name=Dea
Comment=A browser your coding agent can use
Exec=$bin/dea %U
Icon=dea
Type=Application
Categories=Development;
StartupWMClass=dea
Terminal=false
EOF
    ok "Installed" "$bin/dea"
    ;;
esac
