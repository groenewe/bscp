# Nuitka builds

> Part of the bscp developer documentation. See [CLAUDE.md](../CLAUDE.md) for the architecture overview and index.

Two single-file binaries are checked in next to the source: `bscp.amd64`
(x86-64) and `bscp.arm64` (aarch64).  Both were built with Nuitka in
`--mode=onefile` against Python 3.14.3 and **do not require Python on the
client host** (the binary embeds the interpreter and the `bscp` source).
The remote side still needs `python3`, `python2`, `python`, or `perl` on
`PATH` (the binary embeds `remote_script`, `remote_script_mt`, and
`remote_perl`); it only replaces the local interpreter, not the embedded
protocol.  The checked-in binaries predate `--hash-threads`; rebuild them
to pick up the threaded client/remote path.

Build environments:

- `bscp.amd64`: Ubuntu 22.04 (amd64 desktop) (produced binary works on Ubuntu Jammy installs and higher)
- `bscp.arm64`: Ubuntu 24.04 (Raspberry Pi)

To rebuild:

```sh
sudo apt install patchelf
pyenv local 3.14.3
python -m venv nuitka && source nuitka/bin/activate
pip install --upgrade pip wheel Nuitka[all]
python -m nuitka bscp --mode=onefile --static-libpython=yes -o bscp.nuitka
```

`--mode=onefile` produces a single self-extracting executable; the
alternative `--mode=standalone` produces a directory tree and is **not**
the supported configuration.  Because `remote_script` is a plain string
literal (no `inspect.getsource()`), Nuitka's onefile mode works without
any source-bundling tricks.
