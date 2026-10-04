#!/bin/bash
#
# Compile script for Sashimi Kernel.
# Adapted from Sushi to Sashimi.
# Copyright (C) 2024 Akari.
#

set -euo pipefail
SECONDS=0
CLANG_REV="r596125"
CLANG_VERSION="clang-22.0.2"
CLANG_URL="https://github.com/Samw662/aosp-clang-toolchains/releases/download/clang-22/clang-${CLANG_REV}.tar.gz"
GO_UP_URL="${GO_UP_URL:-https://raw.githubusercontent.com/GustavoMends/go-up/master/go-up}"
TC_DIR="$HOME/tc/$CLANG_VERSION"
export PATH="$TC_DIR/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER=Sashimi
export KBUILD_BUILD_HOST=Kernel
export LLVM_DIR="$TC_DIR/bin"
export LLVM=1
AK3_DIR="$HOME/AnyKernel3"
LOG_FILE="sashimi.log"
MIN_FREE_GB=20
TC_TMP=""
: > "$LOG_FILE"

log() {
	printf '%b\n' "$*" | tee -a "$LOG_FILE"
}

die() {
	log "ERROR: $*"
	exit 1
}

cleanup() {
	rm -rf AnyKernel3 ${TC_TMP:+"$TC_TMP"}
}
trap cleanup EXIT

usage() {
	log "Use: $0 -v {bangkk}"
	exit 1
}

if [[ $# -ne 2 || $1 != "-v" ]]; then
	usage
fi

VARIANT="$2"
case "$VARIANT" in
	bangkk) DEFCONFIG="vendor/bangkk_defconfig" ;;
	*) usage ;;
esac

for tool in curl tar make git zip; do
	command -v "$tool" > /dev/null || die "$tool not found. Aborting..."
done

AVAIL_GB=$(df --output=avail -BG . | tail -n 1 | tr -dc '0-9')
if [ "$AVAIL_GB" -lt "$MIN_FREE_GB" ]; then
	die "only ${AVAIL_GB}G free, need at least ${MIN_FREE_GB}G. Aborting..."
fi

setup_clang() {
	local src
	log "Clang not found! Downloading AOSP Clang..."
	mkdir -p "$HOME/tc"
	TC_TMP=$(mktemp -d "$HOME/tc/.dl.XXXXXX")
	if ! curl -fsSL "$CLANG_URL" | tar -xz -C "$TC_TMP" 2>> "$LOG_FILE"; then
		die "Download failed! Aborting..."
	fi
	src="$TC_TMP"
	if [ -d "${TC_TMP}/clang-${CLANG_REV}/bin" ]; then
		src="${TC_TMP}/clang-${CLANG_REV}"
	fi
	rm -rf "$TC_DIR"
	mkdir -p "$TC_DIR"
	mv "$src"/* "$TC_DIR"/
	rm -rf "$TC_TMP"
	TC_TMP=""
	[ -x "${LLVM_DIR}/clang" ] || die "clang still missing after extraction. Aborting..."
	log "Clang setup completed successfully!"
}

if ! [ -x "${LLVM_DIR}/clang" ]; then
	setup_clang
fi

if command -v ccache &> /dev/null; then
	export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
	export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
	export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,include_file_mtime}"
	ccache -z > /dev/null
	CC_COMPILER="ccache ${LLVM_DIR}/clang"
else
	CC_COMPILER="${LLVM_DIR}/clang"
fi

log "\nCompiler info:"
"${LLVM_DIR}/clang" --version | sed -n 1p | tee -a "$LOG_FILE"
"${LLVM_DIR}/ld.lld" --version | sed -n 1p | tee -a "$LOG_FILE"
log "\nCompiling for $DEFCONFIG with variant $VARIANT..."

mkdir -p out
ARGS=(
	CC="${CC_COMPILER}"
	LD="${LLVM_DIR}/ld.lld"
	ARCH=arm64
	AR="${LLVM_DIR}/llvm-ar"
	NM="${LLVM_DIR}/llvm-nm"
	OBJCOPY="${LLVM_DIR}/llvm-objcopy"
	OBJDUMP="${LLVM_DIR}/llvm-objdump"
	READELF="${LLVM_DIR}/llvm-readelf"
	OBJSIZE="${LLVM_DIR}/llvm-size"
	STRIP="${LLVM_DIR}/llvm-strip"
	LLVM=1
	KCFLAGS="-Wno-implicit-enum-enum-cast"
)

make "${ARGS[@]}" O=out "$DEFCONFIG" moto.config | tee -a "$LOG_FILE"

if grep -q '^CONFIG_KSU=y' out/.config && ! grep -qE '^CONFIG_(KSU_SUSFS|KSU_MANUAL_HOOK)=y' out/.config; then
	die "CONFIG_KSU=y needs CONFIG_KSU_SUSFS=y or CONFIG_KSU_MANUAL_HOOK=y. Aborting..."
fi

make "${ARGS[@]}" O=out -j"$(nproc)" | tee -a "$LOG_FILE"

[ -e "out/arch/arm64/boot/Image" ] || die "Image binary not found. Compilation failed!"

log "\nKernel compiled successfully for $DEFCONFIG! Zipping up...\n"
for sym in KSU KSU_SUSFS KSU_MANUAL_HOOK IRQ_SBALANCE; do
	log "$(grep -E "^CONFIG_${sym}=" out/.config || echo "CONFIG_${sym} is not set")"
done

rm -rf AnyKernel3

if [ -d "$AK3_DIR" ]; then
	cp -r "$AK3_DIR" AnyKernel3
	git -C AnyKernel3 checkout -q bangkk
else
	git clone --depth=1 --single-branch -q https://github.com/SashimiKernel/AnyKernel3 -b bangkk AnyKernel3
fi

cp out/.config AnyKernel3/config
cp out/arch/arm64/boot/Image AnyKernel3/Image
[ -f out/arch/arm64/boot/dtb.img ] && cp out/arch/arm64/boot/dtb.img AnyKernel3/dtb
[ -f out/arch/arm64/boot/dtbo.img ] && cp out/arch/arm64/boot/dtbo.img AnyKernel3/dtbo.img

ZIPNAME_PREFIX="Sashimi"
if grep -q "^CONFIG_KSU=y" out/.config; then
	ZIPNAME_PREFIX="${ZIPNAME_PREFIX}-ksu"
	if grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
		ZIPNAME_PREFIX="${ZIPNAME_PREFIX}-susfs"
	fi
fi
ZIPNAME_PREFIX="${ZIPNAME_PREFIX}-$(date '+%Y%m%d-%H%M')"

ZIPNAME="${ZIPNAME_PREFIX}-${VARIANT}.zip"
(cd AnyKernel3 && zip -r9q "../$ZIPNAME" . -x ".git*" "README.md" "*placeholder")

if command -v ccache &> /dev/null; then
	log "\nccache statistics:"
	ccache -s | tee -a "$LOG_FILE"
fi

log "\nCompleted compilation for $DEFCONFIG (variant $VARIANT) in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!"
log "Zip: $ZIPNAME"

if [ "${SKIP_UPLOAD:-0}" != "1" ]; then
	if [ ! -f ./go-up ]; then
		if wget -q "$GO_UP_URL" -O go-up.tmp && [ -s go-up.tmp ] && { [ -z "${GO_UP_SHA256:-}" ] || echo "${GO_UP_SHA256}  go-up.tmp" | sha256sum -c --quiet -; }; then
			mv go-up.tmp go-up
			chmod +x go-up
		else
			rm -f go-up.tmp
			log "Warning: go-up download or verification failed, skipping upload..."
		fi
	fi
	if [ -f ./go-up ]; then
		./go-up "$ZIPNAME" || log "Warning: go-up upload failed, skipping..."
	fi
fi
