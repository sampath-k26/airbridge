#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Building AirBridge 2.0 Native Bridge..."
cd "$DIR/bridge"
cargo build --release
echo "Built binary: $DIR/bridge/target/release/airbridge"
