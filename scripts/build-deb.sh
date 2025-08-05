#!/bin/bash

set -e

# VERSION="$(grep VERSION whatenc.sh | cut -d'"' -f2)"
VERSION="v1.0.0"  # Replace with the actual version if needed

PKG_NAME="whatenc"
PKG_DIR="pkg-staging"
DEB_DIR="${PKG_NAME}_${VERSION}_all"
INSTALL_PATH="$PKG_DIR/usr/bin"

# Clean any previous build
rm -rf "$PKG_DIR"

# Create required folder structure
mkdir -p "$INSTALL_PATH"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/share/man/man1"

# Create control file dynamically
cat <<EOF > "$PKG_DIR/DEBIAN/control"
Package: $PKG_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: all
Maintainer: Mahros <you@example.com>
Description: Detect encoding type of a given string using Bash and iconv
EOF

# Copy source files into the package structure
cp src/copy/copy.sh "$INSTALL_PATH/copy"
chmod 755 "$INSTALL_PATH/copy"

# # Copy man page and compress it
# gzip -c man/copy.1 > "$PKG_DIR/usr/share/man/man1/copy.1.gz"

# Build the package
dpkg-deb --build "$PKG_DIR"

# Rename for clarity
mv "${PKG_DIR}.deb" "${PKG_NAME}_${VERSION}_all.deb"

echo "Package built: ${PKG_NAME}_${VERSION}_all.deb"
