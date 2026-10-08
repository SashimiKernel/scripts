# Scripts - Sashimi Kernel

## Files

**`sashimi.sh`** — Compiles the kernel for `bangkk`, applying `vendor/bangkk_defconfig` followed by `moto.config`. Validates or downloads the Clang toolchain, checks KernelSU configuration, and packages `Image` plus available DTB/DTBO files with AnyKernel3. Produces `Sashimi[-ksu[-susfs]]-<date>-<time>-bangkk.zip`, with suffixes based on the final `.config`.

Uses temporary packaging directories, prevents concurrent builds in the same directory, validates the ZIP against the build, and saves output and errors to `sashimi.log`. Local Git AnyKernel3 templates use only tracked files from `bangkk`.

Usage:

```bash
./sashimi.sh -v bangkk
```

Optional environment variables:

- `SKIP_UPLOAD=1` — skip the `go-up` upload.
- `JOBS`, `MIN_FREE_GB` — build threads and minimum free space (defaults: CPU count and `20` GiB).
- `CLANG_REV`, `CLANG_VERSION`, `CLANG_URL`, `TC_DIR` — toolchain version, download URL and installation path.
- `CLANG_SHA256` — verify the downloaded toolchain archive.
- `AK3_DIR` — local AnyKernel3 template path.
- `GO_UP_URL`, `GO_UP_SHA256` — uploader URL and checksum; verification also covers cached copies.
- `CCACHE_DIR`, `CCACHE_MAXSIZE`, `CCACHE_COMPRESS`, `CCACHE_SLOPPINESS` — ccache settings when installed.
- `KCFLAGS` — additional compiler flags.
- `BUILD_KSU`, `BUILD_SUSFS` — optional `true`/`false` values checked against the final configuration before compiling.

**`bot.sh`** — Runs `sashimi.sh -v bangkk` with `SKIP_UPLOAD=1` and uploads the new or updated ZIP to Telegram. The caption includes the commit, message, BakaSU/SusFS status, duration and workflow link. Shows elapsed time while building, reports failures, and stops the timer and build processes when interrupted.

Validates Telegram API responses, including unchanged-message responses. A failed build, missing ZIP or upload failure returns an error. In CI, validated builds can still be released when Telegram delivery fails.

Usage:

```bash
export BOT_TOKEN=... CHAT_ID=...
./bot.sh
```

Requires exported `BOT_TOKEN` and `CHAT_ID`; `MESSAGE_THREAD_ID` optionally selects a forum topic. `TIMER_INTERVAL` controls progress updates in seconds (default: `10`). In CI, these variables are passed through the workflow `env`.

Run both scripts from the kernel source directory. Requires Bash, Python 3 and standard Linux utilities, including `curl`, `git`, `make`, `tar`, `zip`, `flock`, `sha256sum`, and `jq`/`setsid` for the bot.
