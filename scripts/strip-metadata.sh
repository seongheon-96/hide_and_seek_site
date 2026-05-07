#!/usr/bin/env bash
# Strip identifying metadata from media assets in the repo.
#
# Run before committing new figures/videos to remove identifying metadata.
# Idempotent: safe to re-run; already-stripped files become a no-op.
#
# Usage:
#   scripts/strip-metadata.sh                # processes ./static recursively
#   scripts/strip-metadata.sh path [path...] # processes given files or dirs
#
# Handles:
#   .png                  via Python (stdlib only) — drops eXIf/iTXt/tEXt/zTXt/tIME/iCCP/...
#   .jpg / .jpeg          via jpegtran -copy none, or exiftool -all=, whichever is present
#   .mp4 / .mov / .m4v    via ffmpeg, no re-encode (-c copy), strips container + stream tags
#
# What's NOT handled:
#   .pdf — convert to PNG/SVG instead; PDFs carry XMP/Info dicts that need qpdf or exiftool.
#   .webm / .gif — add cases below if you need them.

set -euo pipefail

# Resolve repo root (script lives in <repo>/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Default target if none given
if [[ $# -eq 0 ]]; then
  set -- static
fi

have() { command -v "$1" >/dev/null 2>&1; }

FFMPEG_BIN=""
if have ffmpeg; then
  FFMPEG_BIN="$(command -v ffmpeg)"
else
  VENV_PY=""
  if [[ -x "$REPO_ROOT/.venv-metadata/bin/python" ]]; then
    VENV_PY="$REPO_ROOT/.venv-metadata/bin/python"
  elif [[ -x "$REPO_ROOT/../.venv-metadata/bin/python" ]]; then
    VENV_PY="$REPO_ROOT/../.venv-metadata/bin/python"
  fi
  if [[ -n "$VENV_PY" ]]; then
    FFMPEG_BIN="$("$VENV_PY" - <<'PY'
import importlib.util
import os
import sys

if importlib.util.find_spec("imageio_ffmpeg") is None:
    sys.exit(1)

import imageio_ffmpeg
exe = imageio_ffmpeg.get_ffmpeg_exe()
if exe and os.path.isfile(exe):
    print(exe)
else:
    sys.exit(1)
PY
)" || true
  fi
fi
if [[ -z "$FFMPEG_BIN" ]]; then
  echo "WARN: ffmpeg not found — video files will be skipped." >&2
fi
if ! have jpegtran && ! have exiftool; then
  echo "WARN: neither jpegtran nor exiftool found — JPEGs will be skipped." >&2
fi
if ! have python3; then
  echo "ERROR: python3 is required for PNG stripping." >&2
  exit 1
fi

strip_png() {
  local f="$1"
  python3 - "$f" <<'PY'
import struct, sys
KEEP = {b'IHDR', b'PLTE', b'tRNS', b'IDAT', b'IEND', b'pHYs', b'sRGB', b'gAMA'}
path = sys.argv[1]
with open(path, 'rb') as fh:
    data = fh.read()
if data[:8] != b'\x89PNG\r\n\x1a\n':
    print(f"  skip (not PNG): {path}")
    sys.exit(0)
out = bytearray(data[:8])
i = 8
dropped = []
while i < len(data):
    length = struct.unpack('>I', data[i:i+4])[0]
    ctype = data[i+4:i+8]
    total = 12 + length
    if ctype in KEEP:
        out += data[i:i+total]
    else:
        dropped.append(ctype.decode('ascii', 'replace'))
    i += total
    if ctype == b'IEND':
        break
if len(out) != len(data):
    with open(path, 'wb') as fh:
        fh.write(bytes(out))
    print(f"  png: dropped {dropped} ({len(data)} -> {len(out)} bytes)")
else:
    print(f"  png: already clean")
PY
}

strip_jpeg() {
  local f="$1"
  if have jpegtran; then
    local tmp="${f}.tmp"
    jpegtran -copy none -optimize -outfile "$tmp" "$f"
    command mv -f "$tmp" "$f"
    echo "  jpeg: stripped (jpegtran)"
  elif have exiftool; then
    exiftool -all= -overwrite_original "$f" >/dev/null
    echo "  jpeg: stripped (exiftool)"
  else
    echo "  jpeg: SKIPPED (no tool)"
  fi
}

strip_video() {
  local f="$1"
  if [[ -z "$FFMPEG_BIN" ]]; then
    echo "  video: SKIPPED (ffmpeg missing)"
    return
  fi
  local tmp="${f}.tmp.mp4"
  "$FFMPEG_BIN" -nostdin -hide_banner -loglevel error -y -i "$f" \
    -map 0 \
    -map_metadata -1 -map_metadata:s:v -1 -map_metadata:s:a -1 -map_chapters -1 \
    -fflags +bitexact -movflags +faststart \
    -c copy "$tmp"
  command mv -f "$tmp" "$f"
  echo "  video: stripped"
}

process_file() {
  local f="$1"
  local f_lc
  f_lc="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  echo "[$f]"
  case "$f_lc" in
    *.png)                         strip_png   "$f" ;;
    *.jpg|*.jpeg)                  strip_jpeg  "$f" ;;
    *.mp4|*.mov|*.m4v)             strip_video "$f" ;;
    *.pdf)                         echo "  pdf: convert to PNG/SVG; this script does not handle PDFs" ;;
    *)                             echo "  skip (unsupported extension)" ;;
  esac
}

for target in "$@"; do
  if [[ -d "$target" ]]; then
    while IFS= read -r -d '' f; do
      process_file "$f"
    done < <(find "$target" -type f \( \
        -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
        -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' \
        -o -iname '*.pdf' \
      \) -print0)
  elif [[ -f "$target" ]]; then
    process_file "$target"
  else
    echo "WARN: not found: $target" >&2
  fi
done

echo ""
echo "Done. Re-run anytime — already-stripped files are a no-op."
