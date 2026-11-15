#!/bin/zsh
# Renders the README's UI images from the real SwiftUI panel view.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
files=(Sources/**/*.swift(N))
files=(${files:#Sources/(App|AppModel|Prompts|StatusPanel).swift})
xcrun swiftc -O -o "$tmp/render" "${files[@]}" scripts/render-ui/main.swift
"$tmp/render" docs/assets
echo "wrote docs/assets/ui.png"
