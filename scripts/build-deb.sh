#!/bin/bash
set -e

PACKAGE_NAME="voidtools"
BUILD_DIR="dist"
DEBIAN_DIR="debian"

mkdir -p "$BUILD_DIR"

# Build directory structure for dpkg
STAGING="pkg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/usr/local/bin"

# Copy all tool binaries into bin
for tool in tools/*; do
  tool_name=$(basename "$tool")
  cp "$tool/$tool_name.sh" "$STAGING/usr/local/bin/$tool_name"
  chmod +x "$STAGING/usr/local/bin/$tool_name"
done

# Copy debian metadata
cp -r "$DEBIAN_DIR" "$STAGING/DEBIAN"

# Build the .deb package
dpkg-deb --build "$STAGING" "$BUILD_DIR/${PACKAGE_NAME}.deb"
