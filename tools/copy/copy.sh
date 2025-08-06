#!/bin/bash
# Copies file contents to clipboard

if [[ -z "$1" || ! -f "$1" ]]; then
    echo "Usage: copy.sh <file>"
    exit 1
fi

xclip -selection clipboard < "$1"
echo "Copied contents of $1 to clipboard"
