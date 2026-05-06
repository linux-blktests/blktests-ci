#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)
#
# Regenerate the architecture diagram PNGs (light + dark) from the
# drawio source file using the drawio-desktop CLI.
#
# Prerequisites (one-time):
#   - drawio-desktop: https://github.com/jgraph/drawio-desktop/releases
#       Fedora/RHEL: sudo dnf install ./drawio-x86_64-*.rpm
#       Debian/Ubuntu: sudo apt install ./drawio-amd64-*.deb
#       macOS: brew install --cask drawio
#   - On headless Linux, xvfb is required:
#       sudo dnf install xorg-x11-server-Xvfb   # Fedora/RHEL
#       sudo apt install xvfb                   # Debian/Ubuntu
#   - rsvg-convert (from librsvg) is used to rasterize the dark SVG to
#     PNG onto a solid background. We don't use drawio's themed SVG
#     export: its dark theme emits CSS light-dark() colors that
#     rsvg-convert can't interpret (it falls back to the light palette),
#     and drawio's PNG export can't set a custom background colour.
#     Instead we bake dark-friendly colours into a copy of the source
#     and rasterize that onto DARK_BG.
#       sudo dnf install librsvg2-tools         # Fedora/RHEL
#       sudo apt install librsvg2-bin           # Debian/Ubuntu

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${SCRIPT_DIR}/blktests-ci-architecture.drawio"
OUT_LIGHT="${SCRIPT_DIR}/blktests-ci-architecture-light.png"
OUT_DARK="${SCRIPT_DIR}/blktests-ci-architecture-dark.png"

# Solid canvas colour for the dark export (GitHub dark). The element
# palette in the recolour step below is tuned to contrast with this.
DARK_BG="#0d1117"

if ! command -v drawio &>/dev/null; then
    echo "Error: drawio not found." >&2
    echo "Install drawio-desktop from:" >&2
    echo "  https://github.com/jgraph/drawio-desktop/releases" >&2
    exit 1
fi

if ! command -v rsvg-convert &>/dev/null; then
    echo "Error: rsvg-convert not found (needed for the dark PNG)." >&2
    echo "Install librsvg (e.g. 'sudo dnf install librsvg2-tools')." >&2
    exit 1
fi

# Wrap with xvfb-run on Linux when no DISPLAY is available, since
# drawio-desktop is an Electron app that still needs an X server even
# for headless export.
DRAWIO=(drawio)
if [[ "$(uname -s)" == "Linux" && -z "${DISPLAY:-}" ]]; then
    if ! command -v xvfb-run &>/dev/null; then
        echo "Error: DISPLAY is unset and xvfb-run is not installed." >&2
        echo "Install Xvfb (e.g. 'sudo dnf install xorg-x11-server-Xvfb')" >&2
        echo "or run this script inside a graphical session." >&2
        exit 1
    fi
    DRAWIO=(xvfb-run -a drawio)
fi

echo "Exporting light mode PNG..."
"${DRAWIO[@]}" --export --format png --border 20 --scale 2 \
    --output "${OUT_LIGHT}" "${INPUT}"

# Dark variant: bake dark-friendly colours into a copy of the source,
# export a plain SVG, then rasterize it onto a solid dark background.
# (See the prerequisites note above for why we don't use --svg-theme.)
echo "Exporting dark mode PNG (recoloured source)..."
DARK_DRAWIO="$(mktemp --suffix=.drawio)"
DARK_SVG="$(mktemp --suffix=.svg)"
trap 'rm -f "${DARK_DRAWIO}" "${DARK_SVG}"' EXIT

# Recolour for a dark canvas: light arrows/borders, dark label chips and
# brighter container labels. Pastel box fills (with their dark text) are
# kept as-is since they read well on dark. Only style strings are edited,
# so geometry and layout are untouched. The palette is tuned for DARK_BG.
python3 - "${INPUT}" "${DARK_DRAWIO}" <<'PY'
import re, sys

FG = "#c9d1d9"          # arrows, outer border, edge-label text
LABEL_CHIP = "#161b22"  # edge-label background chip (masks crossings)
NS_STROKE = "#6e7681"   # dashed namespace borders
NS_FONT = "#adbac7"     # namespace / section labels


def set_kv(style, key, val):
    pat = re.compile(r"(^|;)" + re.escape(key) + r"=[^;]*")
    if pat.search(style):
        return pat.sub(lambda m: m.group(1) + key + "=" + val, style)
    if style and not style.endswith(";"):
        style += ";"
    return style + key + "=" + val + ";"


def transform(style):
    if "endArrow" in style:                         # edge / arrow
        style = set_kv(style, "strokeColor", FG)
        style = set_kv(style, "fontColor", FG)
        return style.replace("labelBackgroundColor=#ffffff",
                             "labelBackgroundColor=" + LABEL_CHIP)
    if "fillColor=none" in style:                   # unfilled container
        if "strokeColor=#000000" in style:          # outer k3s box
            style = style.replace("strokeColor=#000000", "strokeColor=" + FG)
            return set_kv(style, "fontColor", FG)
        if "strokeColor=#666666" in style:          # dashed namespaces
            style = style.replace("strokeColor=#666666", "strokeColor=" + NS_STROKE)
        return set_kv(style, "fontColor", NS_FONT)
    return style                                    # coloured boxes: keep


src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    xml = f.read()
xml = re.sub(r'style="([^"]*)"',
             lambda m: 'style="' + transform(m.group(1)) + '"', xml)
with open(dst, "w") as f:
    f.write(xml)
PY

"${DRAWIO[@]}" --export --format svg --border 20 \
    --output "${DARK_SVG}" "${DARK_DRAWIO}"

# drawio appends a trailing <switch> that renders a 'Text is not SVG -
# cannot display' notice when the consumer doesn't support
# <foreignObject>. rsvg-convert hits this fallback path, so drop the
# notice before rasterizing.
python3 -c "
import re, sys
p = sys.argv[1]
with open(p) as f: s = f.read()
s = re.sub(r'<switch>(?:(?!</switch>).)*Text is not SVG[^<]*</text></a></switch>', '', s, flags=re.S)
with open(p, 'w') as f: f.write(s)
" "${DARK_SVG}"

rsvg-convert --zoom 2 --background-color "${DARK_BG}" \
    --output "${OUT_DARK}" "${DARK_SVG}"

echo "Done:"
echo "  ${OUT_LIGHT}"
echo "  ${OUT_DARK}"
