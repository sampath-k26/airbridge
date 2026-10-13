#!/bin/bash
# Generates a deterministic-size test corpus with random contents.
# Usage: generate-test-files.sh OUT_DIR [--large]   (--large adds 100 MB and 1 GB files)
set -euo pipefail
OUT=${1:?usage: generate-test-files.sh OUT_DIR [--large]}
mkdir -p "$OUT"
cd "$OUT"
rnd() { head -c "$2" /dev/urandom > "$1"; }
rnd "1KB.bin" 1024
rnd "1MB photo.jpg" 1048576
rnd "binary.dat" 3333333
: > "empty file.txt"
rnd "résumé (final).pdf" 250000
rnd "日本語のファイル.txt" 4096
rnd "emoji 🎉 party.zip" 70000
mkdir -p "Folder Ü/Sub folder/deeper"
rnd "Folder Ü/a.txt" 10
rnd "Folder Ü/Sub folder/b c.mp3" 500000
rnd "Folder Ü/Sub folder/deeper/c.mov" 2000000
: > "Folder Ü/Sub folder/deeper/zero.bin"
if [[ "${2:-}" == "--large" ]]; then
  rnd "100MB video.mp4" 104857600
  rnd "1GB archive.zip" 1073741824
fi
echo "generated in $OUT:"; find . -type f | wc -l
