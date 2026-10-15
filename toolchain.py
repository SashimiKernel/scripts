#!/usr/bin/env python3

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

TOOLS = ('clang', 'ld.lld', 'llvm-ar', 'llvm-nm', 'llvm-objcopy',
         'llvm-objdump', 'llvm-readelf', 'llvm-size', 'llvm-strip')
RECEIPT = '.sashimi-toolchain.json'


def identity():
    revision = os.environ.get('CLANG_REV', '06092026')
    checksum = os.environ.get('CLANG_SHA256', '').lower()
    if checksum and (len(checksum) != 64 or any(c not in '0123456789abcdef' for c in checksum)):
        raise ValueError('CLANG_SHA256 must contain 64 hexadecimal digits.')
    return {
        'revision': revision,
        'version': os.environ.get('CLANG_VERSION', 'neutron-clang-24-06092026'),
        'url': os.environ.get('CLANG_URL',
            f'https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/{revision}/neutron-clang-{revision}.tar.zst'),
        'expected_sha256': checksum,
    }


def tools_ready(directory):
    if not all(os.access(directory / 'bin' / tool, os.X_OK) for tool in TOOLS):
        raise ValueError('Toolchain is incomplete.')
    versions = {}
    for tool in ('clang', 'ld.lld'):
        result = subprocess.run([str(directory / 'bin' / tool), '--version'],
                                check=True, capture_output=True, text=True, timeout=15)
        versions[tool] = result.stdout.splitlines()[0]
    return versions


def main():
    expected = identity()
    command = sys.argv[1]
    if command == 'key':
        print(hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest())
        return
    directory = Path(sys.argv[2])
    versions = tools_ready(directory)
    if command == 'write':
        with Path(sys.argv[3]).open('rb') as archive:
            digest = hashlib.sha256()
            for block in iter(lambda: archive.read(1024 * 1024), b''):
                digest.update(block)
            checksum = digest.hexdigest()
        if expected['expected_sha256'] and checksum != expected['expected_sha256']:
            raise ValueError('Clang SHA256 verification failed.')
        receipt = {'identity': expected, 'archive_sha256': checksum, 'compilers': versions}
        (directory / RECEIPT).write_text(json.dumps(receipt, indent=2) + '\n')
    elif command == 'check':
        receipt = json.loads((directory / RECEIPT).read_text())
        if receipt['identity'] != expected or receipt['compilers'] != versions:
            raise ValueError('Toolchain identity changed.')
        if expected['expected_sha256'] and receipt['archive_sha256'] != expected['expected_sha256']:
            raise ValueError('Toolchain checksum changed.')
    else:
        raise ValueError('Unknown command.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
