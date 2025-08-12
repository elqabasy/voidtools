#!/bin/bash

# Main dispatcher for voidtools utility

# Determine the directory where sub-command scripts are located
COMMANDS_DIR="/usr/bin/"

# If no command is given or --help is specified, show usage message
if [[ -z "$1" || "$1" == "--help" ]]; then
    cat <<EOF
Usage: voidtools <command> [options] [input]

Commands:
  copy         		Copy text to clipboard using xsel.
  --help       		Show this help message.
  man <com>  		Show the man page:
					man picofind --will run man for picocfind 

EOF
    exit 0
fi

# Capture the command and shift it off the arguments list
command=$1
shift

# Check if the command script exists and is executable, then execute it with the remaining arguments
if [[ -x "$COMMANDS_DIR/$command" ]]; then
    exec "$COMMANDS_DIR/$command" "$@"
else
    echo "Error: Command '$command' not found."
    echo "Use 'voidtools --help' to see available commands."
    exit 1
fi
