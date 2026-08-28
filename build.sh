#!/bin/bash
# Build ratebridge. Output: ./bin/ratebridge
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -framework CoreAudio -framework Foundation \
    -o bin/ratebridge Sources/main.swift
echo "built: $(pwd)/bin/ratebridge"

# Keep the copy in PATH current. It is a copy, not a symlink, so the tool keeps
# working when the checkout lives on a volume that is not mounted.
# Atomic replace, NOT cp-in-place. Overwriting a running/signed binary in place
# keeps the inode and invalidates its ad-hoc code signature, after which macOS
# SIGKILLs it on exec (exit 137). mv swaps the directory entry instead.
if [ -d "$HOME/.local/bin" ]; then
    cp bin/ratebridge "$HOME/.local/bin/.ratebridge.new"
    mv -f "$HOME/.local/bin/.ratebridge.new" "$HOME/.local/bin/ratebridge"
    echo "installed: $HOME/.local/bin/ratebridge"
fi
