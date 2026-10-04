# Scripts - Sashimi Kernel

## Files

**`sashimi.sh`** — Compiles the kernel for the `bangkk` variant. Downloads/sets up the Clang toolchain if missing, builds `vendor/bangkk_defconfig`, packages the output (`Image`, `dtb.img`, `dtbo.img`) with AnyKernel3, and produces a flashable zip named `Sashimi[-ksu[-susfs]]-<date>-<time>-bangkk.zip` (`-ksu` is added when `CONFIG_KSU=y` in the final `.config`, and `-susfs` is added after it when `CONFIG_KSU_SUSFS=y`).

Usage:
```bash
./sashimi.sh -v bangkk
```

Optional environment variables:
- `SKIP_UPLOAD=1` — skip the `go-up` upload after the build.
- `GO_UP_URL` — where to download `go-up` from (pin it to a commit).
- `GO_UP_SHA256` — if set, the downloaded `go-up` is verified against this hash.
- `CCACHE_DIR`, `CCACHE_MAXSIZE` — ccache settings, used when `ccache` is installed.

**`bot.sh`** — Runs `sashimi.sh -v bangkk` and, on success, uploads the resulting zip to a Telegram chat via bot API, with a caption showing commit hash, commit message, ReSukiSU status, SusFS status, and build duration. While building, it shows a live elapsed-time message that is removed on success or replaced with a failure notice.

Usage:
```bash
export BOT_TOKEN=... CHAT_ID=...
./bot.sh
```

Requires `BOT_TOKEN` and `CHAT_ID` exported in the shell (optionally `MESSAGE_THREAD_ID`). In CI they are passed through the workflow `env`. `TIMER_INTERVAL` (default `10`) sets how often the elapsed-time message is updated, in seconds. Requires `curl` and `jq`.
