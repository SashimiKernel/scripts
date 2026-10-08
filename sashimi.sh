#!/bin/bash
#
# Compile script for Sashimi Kernel.
# Adapted from Sushi to Sashimi.
# Copyright (C) 2024 Akari.
#

set -Eeuo pipefail
SECONDS=0

CLANG_REV="${CLANG_REV:-r596125}"
CLANG_VERSION="${CLANG_VERSION:-clang-22.0.2}"
CLANG_URL="${CLANG_URL:-https://github.com/Samw662/aosp-clang-toolchains/releases/download/clang-22/clang-${CLANG_REV}.tar.gz}"
GO_UP_URL="${GO_UP_URL:-https://raw.githubusercontent.com/GustavoMends/go-up/master/go-up}"
TC_DIR="${TC_DIR:-$HOME/tc/$CLANG_VERSION}"
AK3_DIR="${AK3_DIR:-$HOME/AnyKernel3}"
LOG_FILE="$PWD/sashimi.log"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
TC_TMP=""
AK3_WORK=""
ZIP_TMP=""
UPLOAD_TMP=""
LLVM_TOOLS=(clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-size llvm-strip)

log() {
	printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

set_progress() {
	[[ -n "${SASHIMI_PROGRESS_FILE:-}" ]] || return 0
	if ! { printf '%s %s\n' "$1" "$2" > "${SASHIMI_PROGRESS_FILE}.tmp" &&
		mv -f -- "${SASHIMI_PROGRESS_FILE}.tmp" "$SASHIMI_PROGRESS_FILE"; }; then
		log "Warning: could not update build progress."
	fi
}

die() {
	log "ERROR: $*"
	exit 1
}

cleanup() {
	local status=$? path
	trap - EXIT
	for path in "$TC_TMP" "$AK3_WORK" "$ZIP_TMP" "$UPLOAD_TMP"; do
		if [[ -n "$path" ]]; then
			rm -rf -- "$path" || true
		fi
	done
	exit "$status"
}

on_error() {
	local status=$1 line=$2
	trap - ERR
	log "ERROR: command failed at line $line (exit $status). See $LOG_FILE."
	exit "$status"
}

if [[ $# -ne 2 || $1 != "-v" || $2 != "bangkk" ]]; then
	printf 'Use: %s -v bangkk\n' "$0" >&2
	exit 1
fi

VARIANT="$2"
DEFCONFIG="vendor/bangkk_defconfig"
[[ -f Makefile && -f "arch/arm64/configs/$DEFCONFIG" && -f arch/arm64/configs/moto.config ]] || {
	printf 'ERROR: run this script from the kernel source directory.\n' >&2
	exit 1
}

for tool in curl tar make git zip df awk sed grep cp mv rm mkdir mktemp date nproc tee flock sha256sum dirname chmod python3; do
	command -v "$tool" > /dev/null || {
		printf 'ERROR: %s not found.\n' "$tool" >&2
		exit 1
	}
done

exec 9> .sashimi-build.lock
flock -n 9 || {
	printf 'ERROR: another build is already running in this directory.\n' >&2
	exit 1
}

: > "$LOG_FILE"
trap cleanup EXIT
trap 'on_error "$?" "$LINENO"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

set_progress 0 preparing

JOBS="${JOBS:-$(nproc)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer."
[[ "$MIN_FREE_GB" =~ ^(0|[1-9][0-9]*)$ ]] || die "MIN_FREE_GB must be a nonnegative integer."
AVAIL_KB=$(df -Pk . | awk 'END { print $4 }')
[[ "$AVAIL_KB" =~ ^[0-9]+$ ]] || die "cannot determine free disk space."
(( AVAIL_KB >= MIN_FREE_GB * 1024 * 1024 )) || die "only $((AVAIL_KB / 1024 / 1024)) GiB free; need ${MIN_FREE_GB} GiB."

export ARCH=arm64 SUBARCH=arm64 LLVM=1
export KBUILD_BUILD_USER=Sashimi KBUILD_BUILD_HOST=Kernel
export LLVM_DIR="$TC_DIR/bin"
export PATH="$LLVM_DIR:$PATH"

clang_ready() {
	local tool
	for tool in "${LLVM_TOOLS[@]}"; do
		[[ -x "$1/bin/$tool" ]] || return 1
	done
}

verify_hash() {
	local file=$1 expected=$2 actual
	[[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || return 1
	actual=$(sha256sum -- "$file") || return 1
	actual=${actual%% *}
	[[ "${actual,,}" == "${expected,,}" ]]
}

validate_config() {
	local option ksu_enabled=false susfs_enabled=false expected_susfs
	[[ -s out/.config ]] || die "out/.config was not generated."
	if grep -q '^CONFIG_KSU=y' out/.config; then
		ksu_enabled=true
	fi
	if grep -q '^CONFIG_KSU_SUSFS=y' out/.config; then
		susfs_enabled=true
	fi
	for option in BUILD_KSU BUILD_SUSFS; do
		[[ -z "${!option:-}" || "${!option}" == true || "${!option}" == false ]] || die "$option must be true or false."
	done
	if [[ -n "${BUILD_KSU:-}" && "$ksu_enabled" != "$BUILD_KSU" ]]; then
		die "final KernelSU configuration does not match BUILD_KSU."
	fi
	if [[ -n "${BUILD_SUSFS:-}" ]]; then
		expected_susfs="$BUILD_SUSFS"
		[[ "$ksu_enabled" == true ]] || expected_susfs=false
		[[ "$susfs_enabled" == "$expected_susfs" ]] || die "final SusFS configuration does not match BUILD_SUSFS."
	fi
	if [[ "$ksu_enabled" == true ]] && ! grep -qE '^CONFIG_(KSU_SUSFS|KSU_MANUAL_HOOK)=y' out/.config; then
		die "CONFIG_KSU=y needs CONFIG_KSU_SUSFS=y or CONFIG_KSU_MANUAL_HOOK=y."
	fi
}

setup_clang() {
	local src parent backup
	parent=$(dirname -- "$TC_DIR")
	log "Downloading AOSP Clang..."
	TC_TMP=$(mktemp -d "$parent/.sashimi-clang.XXXXXX")
	curl -fSL --retry 3 --connect-timeout 30 "$CLANG_URL" -o "$TC_TMP/clang.tar.gz" 2>&1 | tee -a "$LOG_FILE"
	if [[ -n "${CLANG_SHA256:-}" ]]; then
		verify_hash "$TC_TMP/clang.tar.gz" "$CLANG_SHA256" || die "Clang SHA256 verification failed."
	fi
	mkdir -p "$TC_TMP/extract"
	tar -xzf "$TC_TMP/clang.tar.gz" -C "$TC_TMP/extract" 2>&1 | tee -a "$LOG_FILE"
	src="$TC_TMP/extract"
	if [[ -d "$src/clang-${CLANG_REV}/bin" ]]; then
		src="$src/clang-${CLANG_REV}"
	fi
	clang_ready "$src" || die "downloaded toolchain is incomplete."
	if [[ -e "$TC_DIR" || -L "$TC_DIR" ]]; then
		mv -- "$TC_DIR" "$TC_TMP/previous"
	fi
	if ! mv -- "$src" "$TC_DIR"; then
		if [[ -e "$TC_TMP/previous" || -L "$TC_TMP/previous" ]]; then
			backup="$TC_TMP/previous"
			if ! mv -- "$backup" "$TC_DIR"; then
				TC_TMP=""
				die "could not restore Clang; previous installation is at $backup."
			fi
		fi
		die "could not install Clang."
	fi
	rm -rf -- "$TC_TMP"
	TC_TMP=""
	log "Clang setup completed successfully!"
}

set_progress 0 toolchain
mkdir -p "$(dirname -- "$TC_DIR")"
exec 8> "${TC_DIR}.lock"
flock 8
if ! clang_ready "$TC_DIR"; then
	setup_clang
fi
exec 8>&-

if command -v ccache > /dev/null; then
	export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
	export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
	export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros,include_file_mtime}"
	ccache -z >> "$LOG_FILE" 2>&1 || log "Warning: could not reset ccache statistics."
	CC_COMPILER="ccache ${LLVM_DIR}/clang"
else
	CC_COMPILER="${LLVM_DIR}/clang"
fi

log ""
log "Compiler info:"
"${LLVM_DIR}/clang" --version | sed -n '1p' | tee -a "$LOG_FILE"
"${LLVM_DIR}/ld.lld" --version | sed -n '1p' | tee -a "$LOG_FILE"
log ""
log "Compiling for $DEFCONFIG with variant $VARIANT..."

mkdir -p out
ARGS=(
	CC="$CC_COMPILER"
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
	KCFLAGS="${KCFLAGS:+$KCFLAGS }-Wno-implicit-enum-enum-cast"
)

set_progress 20 configuration
make "${ARGS[@]}" O=out "$DEFCONFIG" moto.config 2>&1 | tee -a "$LOG_FILE"
validate_config

set_progress 40 compilation
make "${ARGS[@]}" O=out -j"$JOBS" 2>&1 | tee -a "$LOG_FILE"
[[ -s out/arch/arm64/boot/Image ]] || die "Image binary is missing or empty."
validate_config

log ""
log "Kernel compiled successfully! Packaging..."
set_progress 80 packaging
for sym in KSU KSU_SUSFS KSU_MANUAL_HOOK IRQ_SBALANCE CPU_IDLE_GOV_TEO ARM_QCOM_LPM_CPUIDLE_TEO; do
	log "$(grep -E "^CONFIG_${sym}=" out/.config || printf 'CONFIG_%s is not set\n' "$sym")"
done

AK3_WORK=$(mktemp -d "$PWD/.sashimi-ak3.XXXXXX")
if [[ -d "$AK3_DIR" ]]; then
	if [[ -f "$AK3_DIR/.git" || -d "$AK3_DIR/.git" ]]; then
		git -C "$AK3_DIR" archive bangkk | tar -xf - -C "$AK3_WORK"
	else
		cp -a "$AK3_DIR/." "$AK3_WORK/"
	fi
else
	git clone --depth=1 --single-branch -q -b bangkk https://github.com/SashimiKernel/AnyKernel3 "$AK3_WORK" 2>&1 | tee -a "$LOG_FILE"
fi

[[ -f "$AK3_WORK/anykernel.sh" ]] || die "AnyKernel3 template has no anykernel.sh."
rm -f -- "$AK3_WORK/Image" "$AK3_WORK/Image.gz" "$AK3_WORK/Image.gz-dtb" "$AK3_WORK/dtb" "$AK3_WORK/dtbo.img" "$AK3_WORK/config"
cp out/.config "$AK3_WORK/config"
cp out/arch/arm64/boot/Image "$AK3_WORK/Image"
if [[ -s out/arch/arm64/boot/dtb.img ]]; then
	cp out/arch/arm64/boot/dtb.img "$AK3_WORK/dtb"
fi
if [[ -s out/arch/arm64/boot/dtbo.img ]]; then
	cp out/arch/arm64/boot/dtbo.img "$AK3_WORK/dtbo.img"
fi

ZIPNAME_PREFIX="Sashimi"
if grep -q '^CONFIG_KSU=y' out/.config; then
	ZIPNAME_PREFIX+="-ksu"
	if grep -q '^CONFIG_KSU_SUSFS=y' out/.config; then
		ZIPNAME_PREFIX+="-susfs"
	fi
fi
ZIPNAME="${ZIPNAME_PREFIX}-$(date '+%Y%m%d-%H%M')-${VARIANT}.zip"
ZIP_TMP=$(mktemp -d "$PWD/.sashimi-zip.XXXXXX")
(
	cd "$AK3_WORK"
	zip -r9q "$ZIP_TMP/$ZIPNAME" . -x '.git' '.git/*' '.git*' 'README.md' '*placeholder'
) 2>&1 | tee -a "$LOG_FILE"
[[ -s "$ZIP_TMP/$ZIPNAME" ]] || die "ZIP creation failed."
python3 - "$ZIP_TMP/$ZIPNAME" <<'PY' 2>&1 | tee -a "$LOG_FILE"
import hashlib
import sys
import zipfile
from pathlib import Path

boot = Path('out/arch/arm64/boot')

def digest(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(block)
    return result.digest()

with zipfile.ZipFile(sys.argv[1]) as archive:
    if archive.read('config') != Path('out/.config').read_bytes():
        raise SystemExit('ERROR: packaged configuration does not match the build.')
    for filename, member in (('Image', 'Image'), ('dtb.img', 'dtb'), ('dtbo.img', 'dtbo.img')):
        source = boot / filename
        if not source.is_file() or not source.stat().st_size:
            if filename == 'Image':
                raise SystemExit('ERROR: Image binary is missing or empty.')
            continue
        with source.open('rb') as original, archive.open(member) as packaged:
            if digest(original) != digest(packaged):
                raise SystemExit(f'ERROR: packaged {member} does not match the build.')
PY
mv -f -- "$ZIP_TMP/$ZIPNAME" "$PWD/$ZIPNAME"
set_progress 100 complete

if command -v ccache > /dev/null; then
	log ""
	log "ccache statistics:"
	ccache -s 2>&1 | tee -a "$LOG_FILE" || log "Warning: could not read ccache statistics."
fi

log ""
log "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!"
log "Zip: $ZIPNAME"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	printf 'build_success=true\nzip_file=%s\n' "$ZIPNAME" >> "$GITHUB_OUTPUT"
fi

if [[ "${SKIP_UPLOAD:-0}" != "1" ]]; then
	UPLOAD_READY=1
	if [[ ! -s ./go-up ]]; then
		UPLOAD_TMP=$(mktemp -d "$PWD/.sashimi-upload.XXXXXX")
		if curl -fSL --retry 3 --connect-timeout 30 "$GO_UP_URL" -o "$UPLOAD_TMP/go-up" >> "$LOG_FILE" 2>&1 && [[ -s "$UPLOAD_TMP/go-up" ]]; then
			if [[ -n "${GO_UP_SHA256:-}" ]] && ! verify_hash "$UPLOAD_TMP/go-up" "$GO_UP_SHA256"; then
				UPLOAD_READY=0
				log "Warning: go-up SHA256 verification failed; skipping upload."
			else
				if ! { chmod +x "$UPLOAD_TMP/go-up" && mv -f -- "$UPLOAD_TMP/go-up" ./go-up; }; then
					UPLOAD_READY=0
					log "Warning: could not install go-up; skipping upload."
				fi
			fi
		else
			UPLOAD_READY=0
			log "Warning: go-up download failed; skipping upload."
		fi
	fi
	if [[ "$UPLOAD_READY" == "1" && -n "${GO_UP_SHA256:-}" ]] && ! verify_hash ./go-up "$GO_UP_SHA256"; then
		UPLOAD_READY=0
		log "Warning: cached go-up SHA256 verification failed; skipping upload."
	fi
	if [[ "$UPLOAD_READY" == "1" ]]; then
		if chmod +x ./go-up; then
			./go-up "$ZIPNAME" 2>&1 | tee -a "$LOG_FILE" || log "Warning: go-up upload failed."
		else
			log "Warning: could not make go-up executable; skipping upload."
		fi
	fi
fi
