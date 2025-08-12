# copy

Copies text or file contents to the system clipboard using `xsel`.

## Usage

```sh
voidtools copy [TEXT | FILE ...]
```
You can provide one or more strings or file paths as arguments. If a file is given, its contents are copied. If a string is given, the string itself is copied. You can also pipe input via stdin.

## Requirements
- `xsel` must be installed. If not present, the script will prompt you to install it:
  ```sh
  sudo apt update && sudo apt install -y xsel
  ```

## Examples

Copy a string:
```sh
voidtools copy "picoCTF{flag_here}"
```

Copy contents of a file:
```sh
voidtools copy flag.txt
```

Copy multiple files and/or strings:
```sh
voidtools copy flag.txt "extra info"
```

Copy from stdin:
```sh
echo "picoCTF{flag_here}" | voidtools copy
```

## Output
- On success: `[+] Copied to clipboard!`
- On empty input: `[-] Empty output. Nothing copied!`

## Author
Mahros AL-Qabasy

Report issues at https://github.com/mahros-alqabasy/picoctf/issues
