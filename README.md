# Scripts - Sashimi Kernel

## Files

**`sashimi.sh`** — Compiles the kernel for the `bangkk` variant. Downloads/sets up the Clang toolchain if missing, builds `vendor/bangkk_defconfig`, packages the output (`Image`, `dtb.img`, `dtbo.img`) with AnyKernel3, and produces a flashable zip.

Usage:
```bash
./sashimi.sh -v bangkk
```

**`bot.sh`** — Runs `sashimi.sh -v bangkk` and, on success, uploads the resulting zip to a Telegram chat via bot API, with a caption showing commit hash, commit message, and build duration.

Usage:
```bash
./bot.sh
```

Requires `BOT_TOKEN` and `CHAT_ID` (optionally `MESSAGE_THREAD_ID`), set via `.env` or exported in the shell.
