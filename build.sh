#!/bin/bash
# Build ratebridge. Output: ./bin/ratebridge
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
# Every file in Sources/, not a named one: a second file that the build does not
# know about fails at link time with a message about the symbol, not the file.
# Swift allows top-level code only in main.swift, so the others are declarations.
swiftc -O -framework CoreAudio -framework Foundation \
    -o bin/ratebridge Sources/*.swift
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
