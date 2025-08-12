# voidtools

A growing collection of handmade Linux command-line helper tools, designed to make common tasks easier and faster. Each subcommand is a standalone utility, and new tools are added over time as needed.

## Overview
`voidtools` acts as a dispatcher for its subcommands. You invoke a subcommand by running:

```sh
voidtools <subcommand> [options] [arguments]
```

## Features
- Modular: Add new subcommands as you invent them
- Simple: Each tool does one thing well
- Linux-focused: Built for everyday Linux workflows

## Example Subcommands
- `copy` — Copy text or file contents to the clipboard using xsel

## Usage
Show help and available subcommands:
```sh
voidtools --help
```

Run a subcommand:
```sh
voidtools copy "some text"
voidtools picofind challenge_output.txt
```

Show the manual for a subcommand:
```sh
voidtools man copy
```

## Adding Your Own Tools
To add a new subcommand, create a script and place it in the appropriate directory (e.g., `/usr/bin/` or your custom path). Update the dispatcher if needed.

## Requirements
Some subcommands may require additional tools (e.g., `xsel` for clipboard operations).

## Repository
https://github.com/elqabasy/voidtools

## Author
Mahros AL-Qabasy

## Bugs & Contributions
Report issues or contribute at: https://github.com/elqabasy/voidtools/issues
