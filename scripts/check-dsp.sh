#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun clang -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I'Volume Mixer' 'Volume Mixer/MixerDSP.c' Tests/render_test.c \
    -framework CoreAudio -o "$tmp/render_test"
"$tmp/render_test"
echo "DSP checks passed."
