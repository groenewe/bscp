# Nuitka builds

> Part of the bscp developer documentation. See [CLAUDE.md](../CLAUDE.md) for the architecture overview and index.

`bscp` is a plain Python 3 script and normally runs straight from the source
file.  With [Nuitka](https://nuitka.net/) it can be compiled into a single
self-contained executable.  Reasons to do so:

- **No Python on the client.**  The binary embeds the interpreter, so it runs
  on hosts that have no Python 3 at all.
- **A newer, faster Python than the host ships.**  The embedded interpreter
  is whichever version you build against, independent of the host's.  Recent
  CPython releases are generally faster (each version brings further
  optimisation) and nicer to use — e.g. 3.14 colourises syntax-error and
  traceback output.  Build against a current CPython to get those gains even
  on an old host.

The binary embeds both the interpreter and the `bscp` source — including the
remote payloads (`remote_script`, `remote_script_mt`, `remote_perl`) — so it
only replaces the *local* interpreter.  The **remote side is unaffected**: it
still needs `python3`, `python2`, `python`, or `perl` on its `PATH`.

These binaries are **not shipped in the repository** (`.gitignore` keeps them
out — they are large, architecture-specific, and quickly go stale).  Build
your own with the recipe below.

## Prerequisites

- A C toolchain (`gcc`/`clang` + headers) — Nuitka compiles to C.
- `patchelf` — required by `--mode=onefile` on Linux
  (`sudo apt install patchelf` on Debian/Ubuntu).
- A Python 3 interpreter to embed.  Any recent 3.x works; pin a specific
  version (e.g. with `pyenv`) if you want a reproducible build.

## Build

Run on the **target architecture and OS** — Nuitka does **not**
cross-compile.  Produce the x86-64 binary on an x86-64 host and the aarch64
binary on an aarch64 host (e.g. a Raspberry Pi).  Build on the *oldest* glibc
/ distro you need to support; the resulting binary runs on that release and
newer ones.

```sh
sudo apt install patchelf                       # Linux onefile dependency
pyenv local 3.14.3                              # optional: choose the embedded Python
python -m venv nuitka && . nuitka/bin/activate  # clean, isolated build venv
pip install --upgrade pip wheel 'Nuitka[all]'
python -m nuitka bscp --mode=onefile --static-libpython=yes -o bscp.nuitka
```

The output `bscp.nuitka` is a single self-extracting executable.  If you keep
binaries for several platforms, rename per target by your own convention —
e.g. `bscp.amd64` (x86-64) and `bscp.arm64` (aarch64); the name carries no
meaning to the tool itself.

## Notes

- **`--mode=onefile` is the supported configuration.**  It produces one
  executable.  `--mode=standalone` produces a directory tree instead and is
  not supported here.
- **No source-bundling tricks needed.**  The remote payloads are plain string
  literals (the code never calls `inspect.getsource()`), so onefile embeds
  them automatically — this is what keeps `bscp` frozen-friendly (see also
  [PROTOCOL.md](../PROTOCOL.md)).
- **Keep binaries current.**  A built binary embeds a snapshot of the source;
  rebuild after any change that touches the client or the embedded remote
  payloads (for example, the `--hash-threads` threading paths).
- **Test a built binary** against the regression suite by pointing `BSCP` at
  it:

  ```sh
  BSCP=./bscp.nuitka ./tests.sh
  ```

- **Clean up build artifacts** afterwards:

  ```sh
  rm -rf bscp.build bscp.dist bscp.onefile-build __pycache__
  ```
