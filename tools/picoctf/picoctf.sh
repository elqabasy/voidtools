#!/bin/bash
# Scans a file for picoCTF flags

grep -oP 'picoCTF\{.*?\}' "$1"
