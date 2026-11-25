#!/bin/sh
# Install Dea on macOS or Linux:
#
#   curl -fsSL https://raw.githubusercontent.com/neonn0d/dea-releases/main/install.sh | sh
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
set -eu

REPO="neonn0d/dea-releases"
say() { printf '%s\n' "$*"; }
fail() { printf 'Dea install: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have curl || fail "curl is needed."
os=$(uname -s)
machine=$(uname -m)

# Which release file suits this computer.
case "$os" in
  Darwin)
    # A terminal running under Rosetta reports x86_64 on an Apple silicon Mac.
    if [ "$machine" = "arm64" ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then suffix="-arm64.zip"; else suffix="-x64.zip"; fi
    kind="mac"
    ;;
  Linux)
    [ "$machine" = "x86_64" ] || fail "Dea for Linux is built for x86_64 only; this computer is $machine."
    kind="${DEA_KIND:-}"
    if [ -z "$kind" ]; then
      if have pacman; then kind="pacman"; elif have apt-get; then kind="deb"; else kind="appimage"; fi
    fi
    case "$kind" in
      pacman) suffix="-x86_64.pkg.tar.xz" ;;
      deb) suffix="-amd64.deb" ;;
      appimage) suffix="-x86_64.AppImage" ;;
      *) fail "DEA_KIND must be appimage, deb or pacman." ;;
    esac
    ;;
  *) fail "This script installs Dea on macOS and Linux. For Windows, download the installer from https://github.com/$REPO/releases" ;;
esac

# The release, from GitHub: file names, download addresses and checksums.
if [ -n "${DEA_VERSION:-}" ]; then api="https://api.github.com/repos/$REPO/releases/tags/v${DEA_VERSION#v}"; else api="https://api.github.com/repos/$REPO/releases/latest"; fi
release=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api") || fail "Could not read the release list from GitHub. Check your connection, or download from https://github.com/$REPO/releases"

# One line per file: name, checksum, address.
files=$(printf '%s\n' "$release" | awk '
  /"name": *"Dea-/ { name = $0; sub(/.*"name": *"/, "", name); sub(/".*/, "", name) }
  /"digest": *"sha256:/ { digest = $0; sub(/.*"sha256:/, "", digest); sub(/".*/, "", digest) }
  /"browser_download_url":/ { url = $0; sub(/.*"browser_download_url": *"/, "", url); sub(/".*/, "", url); if (name != "") print name, digest, url; name = ""; digest = "" }
')
# The name must be exactly Dea-<version><suffix>: "-x64.zip" alone would also
# match the Windows zip.
line=$(printf '%s\n' "$files" | awk -v s="$suffix" '{ v = $1; if (substr(v, 1, 4) != "Dea-" || length(v) <= length(s) + 4) next; if (substr(v, length(v) - length(s) + 1) != s) next; mid = substr(v, 5, length(v) - length(s) - 4); if (mid ~ /^[0-9][0-9.]*$/) { print; exit } }')
[ -n "$line" ] || fail "This release has no ${suffix#-} build. See https://github.com/$REPO/releases"
name=$(printf '%s' "$line" | awk '{print $1}')
sum=$(printf '%s' "$line" | awk '{print $2}')
url=$(printf '%s' "$line" | awk '{print $3}')
printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' || fail "The release publishes no checksum for $name, so it will not be installed."
case "$url" in https://github.com/"$REPO"/releases/download/*) ;; *) fail "Unexpected download address: $url" ;; esac

if [ -n "${DEA_DRY_RUN:-}" ]; then
  say "Would download $name"
  say "  from $url"
  say "  and check SHA-256 $sum"
  case "$kind" in
    mac) say "Would put Dea.app in /Applications (or ~/Applications if that is not writable)." ;;
    pacman) say "Would run: sudo pacman -U $name" ;;
    deb) say "Would run: sudo apt-get install ./$name" ;;
    appimage) say "Would put the AppImage in ${DEA_BIN_DIR:-$HOME/.local/bin}/dea and add a menu entry." ;;
  esac
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dea-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading $name ..."
curl -fL --progress-bar -o "$tmp/$name" "$url" || fail "The download failed. Try again."

if have sha256sum; then got=$(sha256sum "$tmp/$name" | awk '{print $1}'); elif have shasum; then got=$(shasum -a 256 "$tmp/$name" | awk '{print $1}'); else fail "Neither sha256sum nor shasum is available to check the download."; fi
[ "$got" = "$sum" ] || fail "The download does not match the release's checksum, so it was not installed. Try again."

# sudo for a package install; plain when already root.
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
    say "Dea is installed in $target"
    say "Open it from Launchpad or Spotlight, or run: open \"$target\""
    ;;
  pacman)
    say "Installing the package (your password may be asked) ..."
    as_root pacman -U --noconfirm "$tmp/$name"
    say "Dea is installed. Open it from your app menu, or run: dea"
    ;;
  deb)
    say "Installing the package (your password may be asked) ..."
    chmod 644 "$tmp/$name"; chmod 755 "$tmp"
    as_root apt-get install -y "$tmp/$name"
    say "Dea is installed. Open it from your app menu, or run: dea"
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
    say "Dea is installed as $bin/dea, with an entry in your app menu."
    case ":$PATH:" in *":$bin:"*) say "Run: dea" ;; *) say "Run: $bin/dea   ($bin is not on your PATH)" ;; esac
    say "If it does not start, your system may need FUSE for AppImages (libfuse2)."
    ;;
esac
