#!/bin/bash

set -e

VERSION=$(git describe --tags --always || date +%s)

PKG_NAME="voidtools"
BUILD_DIR="pkg-staging"
DIST_DIR="dist"

# Clean previous builds
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR/DEBIAN"
mkdir -p "$BUILD_DIR/usr/local/bin"
mkdir -p "$DIST_DIR"

# Copy all tool scripts into the bin directory
for tool_dir in tools/*; do
    tool_script="$tool_dir/$(basename "$tool_dir").sh"
    if [[ -f "$tool_script" ]]; then
        cp "$tool_script" "$BUILD_DIR/usr/local/bin/$(basename "$tool_dir")"
        chmod +x "$BUILD_DIR/usr/local/bin/$(basename "$tool_dir")"
    fi
done

# Create control file
cat <<EOF > "$BUILD_DIR/DEBIAN/control"
Package: $PKG_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: all
Maintainer: Mahros <your.email@example.com>
Description: A toolkit for security and productivity utilities.
EOF

# Build the .deb package
dpkg-deb --build "$BUILD_DIR"

# Move result to dist/
mv "${BUILD_DIR}.deb" "$DIST_DIR/${PKG_NAME}.deb"
