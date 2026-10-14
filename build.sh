#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd -P)"
out="${AGENT_SCREEN_OUTPUT_DIR:-$root/dist}"
mkdir -p "$out"
clang="$(xcrun --sdk macosx --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(-fobjc-arc -Wall -Wextra -Werror -g0 -isysroot "$sdk" -mmacosx-version-min=14.0)
"$clang" "${flags[@]}" -I "$root/native" \
  "$root/native/AgentScreenLite.m" "$root/native/AppWorkspace.m" "$root/native/VDVirtualDisplay.m" \
  -framework AppKit -framework CoreGraphics -framework ImageIO -framework IOKit -framework ApplicationServices \
  -o "$out/AgentScreenLite"
chmod 755 "$out/AgentScreenLite"
/usr/bin/codesign --force --sign - "$out/AgentScreenLite"
/usr/bin/codesign --verify --strict "$out/AgentScreenLite"
printf 'Built: %s\n' "$out/AgentScreenLite"
