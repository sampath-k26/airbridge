#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Building AirBridge..."
cd "$DIR"
cargo build --release
echo "Binary created: $DIR/target/release/airbridge"
