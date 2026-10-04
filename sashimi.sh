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
: > "$LOG_FILE"

usage() {
	echo "Use: $0 -v {bangkk}" | tee -a "$LOG_FILE"
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

AVAIL_GB=$(df --output=avail -BG . | tail -n 1 | tr -dc '0-9')
if [ "$AVAIL_GB" -lt "$MIN_FREE_GB" ]; then
	echo "ERROR: only ${AVAIL_GB}G free, need at least ${MIN_FREE_GB}G. Aborting..." | tee -a "$LOG_FILE"
	exit 1
fi

if ! [ -x "${LLVM_DIR}/clang" ]; then
	echo "Clang not found! Downloading AOSP Clang..." | tee -a "$LOG_FILE"
	mkdir -p "$HOME/tc"
	TC_TMP=$(mktemp -d "$HOME/tc/.dl.XXXXXX")
	if ! curl -fsSL "$CLANG_URL" | tar -xz -C "$TC_TMP" 2>> "$LOG_FILE"; then
		rm -rf "$TC_TMP"
		echo "Download failed! Aborting..." | tee -a "$LOG_FILE"
		exit 1
	fi
	TC_SRC="$TC_TMP"
	if [ -d "${TC_TMP}/clang-${CLANG_REV}/bin" ]; then
		TC_SRC="${TC_TMP}/clang-${CLANG_REV}"
		fi
	fi
	rm -rf "$TC_DIR"
	mkdir -p "$TC_DIR"
	mv "$TC_SRC"/* "$TC_DIR"/
	rm -rf "$TC_TMP"
	if ! [ -x "${LLVM_DIR}/clang" ]; then
		echo "ERROR: clang still missing after extraction. Aborting..." | tee -a "$LOG_FILE"
		exit 1
	fi
	echo "Clang setup completed successfully!" | tee -a "$LOG_FILE"
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

echo -e "\nCompiler info:" | tee -a "$LOG_FILE"
"${LLVM_DIR}/clang" --version | head -n 1 | tee -a "$LOG_FILE"
"${LLVM_DIR}/ld.lld" --version | head -n 1 | tee -a "$LOG_FILE"
echo -e "\nCompiling for $DEFCONFIG with variant $VARIANT..." | tee -a "$LOG_FILE"

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
make "${ARGS[@]}" O=out -j"$(nproc)" | tee -a "$LOG_FILE"

if [ ! -e "out/arch/arm64/boot/Image" ]; then
	echo "ERROR: Image binary not found. Compilation failed!" | tee -a "$LOG_FILE"
	exit 1
fi

echo -e "\nKernel compiled successfully for $DEFCONFIG! Zipping up...\n" | tee -a "$LOG_FILE"

cleanup() {
	rm -rf AnyKernel3
}
trap cleanup EXIT
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
	echo -e "\nccache statistics:" | tee -a "$LOG_FILE"
	ccache -s | tee -a "$LOG_FILE"
fi

echo -e "\nCompleted compilation for $DEFCONFIG (variant $VARIANT) in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!" | tee -a "$LOG_FILE"
echo "Zip: $ZIPNAME" | tee -a "$LOG_FILE"

if [ "${SKIP_UPLOAD:-0}" != "1" ]; then
	if [ ! -f ./go-up ]; then
		if wget -q "$GO_UP_URL" -O go-up.tmp && [ -s go-up.tmp ] && { [ -z "${GO_UP_SHA256:-}" ] || echo "${GO_UP_SHA256}  go-up.tmp" | sha256sum -c --quiet -; }; then
			mv go-up.tmp go-up
			chmod +x go-up
		else
			rm -f go-up.tmp
			echo "Warning: go-up download or verification failed, skipping upload..." | tee -a "$LOG_FILE"
		fi
	fi
	if [ -f ./go-up ]; then
		./go-up "$ZIPNAME" || echo "Warning: go-up upload failed, skipping..." | tee -a "$LOG_FILE"
	fi
fi
