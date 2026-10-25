# Scripts - Sashimi Kernel

## Files

**`sashimi.sh`** — Compiles the kernel for `bangkk`, applying `vendor/bangkk_defconfig` followed by `moto.config`. Validates or downloads AOSP Clang 22 (`r596125`), checks KernelSU configuration, and packages `Image` plus available DTB/DTBO files with AnyKernel3. Produces `Sashimi[-ksu[-susfs]]-<date>-<time>-bangkk.zip`, with suffixes based on the final `.config`.

`sashimi.sh` uses GNU `size` from `binutils` when `llvm-size` is unavailable. Other required LLVM tools remain mandatory, with missing executables listed in validation errors.

Records source revisions, toolchain identity and checksums in `out/build-info.json`. The flashable ZIP preserves recovery tools, module helpers and vendor ramdisk payloads, and includes a complete `SHA256SUMS` manifest. Tests, the root README, `config` and `build-info.json` are excluded. Uses temporary packaging directories, prevents concurrent builds in the same directory, validates every ZIP checksum against the build, and saves output and errors to `sashimi.log`. Local Git AnyKernel3 templates use only tracked files from `bangkk`.

Usage:

```bash
./sashimi.sh -v bangkk
```

Optional environment variables:

- `SKIP_UPLOAD=1` — skip the `go-up` upload.
- `JOBS`, `MIN_FREE_GB` — build threads and minimum free space (defaults: CPU count and `20` GiB).
- `CLANG_REV`, `CLANG_VERSION`, `CLANG_URL`, `TC_DIR` — toolchain version, download URL and installation path. Defaults to AOSP revision `r596125`, identity `clang-22.0.2`, and `$HOME/tc/clang-22.0.2`.
- Default archive: https://github.com/samw662/aosp-clang-toolchains/releases/download/clang-22/clang-r596125.tar.gz
- `CLANG_SHA256` — verify the downloaded toolchain archive.
- `AK3_DIR` — local AnyKernel3 template path.
- `GO_UP_URL`, `GO_UP_SHA256` — uploader URL and checksum; verification also covers cached copies.
- `CCACHE_DIR`, `CCACHE_MAXSIZE`, `CCACHE_COMPRESS`, `CCACHE_SLOPPINESS` — ccache settings when installed.
- `KCFLAGS` — additional compiler flags.
- `BUILD_KSU`, `BUILD_SUSFS` — optional `true`/`false` values checked against the final configuration before compiling.

**`bot.sh`** — Runs `sashimi.sh -v bangkk` with `SKIP_UPLOAD=1` and uploads the new or updated ZIP to Telegram. The caption includes the commit, message, BakaSU/SusFS status, duration and workflow link. Shows a continuous text bar for four build stages, animated activity, stage/total elapsed time and Kbuild actions started, and detects linking, BTF and Image generation from build output. The bar tracks stages, without estimating a compilation percentage. Reports failures, and stops the timer and build processes when interrupted.

Validates Telegram responses, including unchanged messages, and reports upload errors. Respects `retry_after` for up to two retries of at most 60 seconds each. A failed build, missing ZIP or upload failure returns an error. In CI, validated builds can still be released when Telegram delivery fails.

Usage:

```bash
export BOT_TOKEN=... CHAT_ID=...
./bot.sh
```

Requires exported `BOT_TOKEN` and `CHAT_ID`; `MESSAGE_THREAD_ID` optionally selects a forum topic. `TIMER_INTERVAL` controls progress updates in seconds (default: `10`). `PROGRESS_BAR_STYLE` selects `blocks` (default, `█▒░`) or pure `ascii` (`#=-`). In CI, these variables are passed through the workflow `env`.

Keep `toolchain.py` beside the scripts. Toolchain reuse requires a matching revision, URL, version and optional checksum. Run both scripts from the kernel source directory. Requires Bash, Python 3 and standard Linux utilities, including `curl`, `git`, `make`, `tar` (with compression auto-detection), `zstd` (for `.tar.zst` archives), `zip`, `flock`, `sha256sum`, and `awk`/`jq`/`setsid` for the bot.
