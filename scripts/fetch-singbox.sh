#!/bin/bash
# Скачивает официальный sing-box в OUTDIR (имя: sing-box или sing-box.exe).
# Usage: fetch-singbox.sh <os> <arch> <outdir>
#   os:   darwin | linux | windows
#   arch: amd64 | arm64
# Env:    SINGBOX_VERSION (default: 1.14.4)
set -euo pipefail

OS="${1:?os (darwin|linux|windows)}"
ARCH="${2:?arch (amd64|arm64)}"
OUTDIR="${3:?outdir}"
VERSION="${SINGBOX_VERSION:-1.14.4}"

case "$OS-$ARCH" in
  darwin-amd64|darwin-arm64|linux-amd64|linux-arm64|windows-amd64|windows-arm64) ;;
  *) echo "unsupported: $OS/$ARCH" >&2; exit 1 ;;
esac

BIN_NAME="sing-box"
ARCHIVE="sing-box-${VERSION}-${OS}-${ARCH}.tar.gz"
if [[ "$OS" == "windows" ]]; then
  BIN_NAME="sing-box.exe"
  ARCHIVE="sing-box-${VERSION}-${OS}-${ARCH}.zip"
fi

URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${ARCHIVE}"
mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetch sing-box v${VERSION} ($OS/$ARCH)..."
curl -fsSL -o "$TMP/$ARCHIVE" "$URL"

mkdir -p "$TMP/extract"
if [[ "$ARCHIVE" == *.zip ]]; then
  unzip -q "$TMP/$ARCHIVE" -d "$TMP/extract"
else
  tar -xzf "$TMP/$ARCHIVE" -C "$TMP/extract"
fi

FOUND="$(find "$TMP/extract" -type f \( -name sing-box -o -name sing-box.exe \) | head -1)"
if [[ -z "$FOUND" ]]; then
  echo "sing-box binary not found in archive" >&2
  find "$TMP/extract" >&2
  exit 1
fi

# убрать старые бинарники, чтобы go:embed не подхватил чужую платформу
rm -f "$OUTDIR/sing-box" "$OUTDIR/sing-box.exe"
cp "$FOUND" "$OUTDIR/$BIN_NAME"
chmod +x "$OUTDIR/$BIN_NAME"

LICENSE="$(find "$TMP/extract" -type f -name LICENSE | head -1 || true)"
if [[ -n "$LICENSE" ]]; then
  cp "$LICENSE" "$OUTDIR/sing-box-LICENSE"
fi

# маркер версии для переустановки при обновлении
echo "$VERSION" > "$OUTDIR/sing-box.version"
echo "OK: $OUTDIR/$BIN_NAME ($(du -h "$OUTDIR/$BIN_NAME" | awk '{print $1}'))"
