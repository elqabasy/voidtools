#!/bin/bash

# Ensure xsel is installed
if ! command -v xsel &> /dev/null; then
    echo "Error: xsel is not installed. Please install it to use clipboard copying."
        echo "Run: sudo apt update && sudo apt install -y xsel"
    exit 1
fi

output=""

for arg in "$@"; do
    if [[ -f "$arg" ]]; then
        output+=$(cat "$arg")
        output+=$'\n'
    else
        output+="$arg"
        output+=$'\n'
    fi
done

if [ ! -t 0 ]; then
    piped=$(cat)
    if [[ -n "$piped" ]]; then
        output+="$piped"
        output+=$'\n'
    fi
fi

# Check if output is empty
if [[ -z "$output" ]]; then
    echo "[-] Empty output. Nothing copied!"
    exit 1
fi

# Copy the combined content to the clipboard
echo -n "$output" | xsel --clipboard --input
echo "[+] Copied to clipboard!"