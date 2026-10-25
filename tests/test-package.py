from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile
import zipfile

source = (Path(__file__).resolve().parents[1] / 'sashimi.sh').read_text()
program = source.split("<<'PYZIP'", 1)[1].split('\n', 1)[1].split('\nPYZIP', 1)[0]
with tempfile.TemporaryDirectory() as td:
    root = Path(td) / 'package'
    root.mkdir()
    runtime = {
        'anykernel.sh', 'Image', 'tools/busybox', 'tools/sashimi-flash.sh',
        'tools/lpmake', 'tools/resize2fs', 'place-modules.sh', 'resize_vendor.sh',
        'modules-load-recovery.txt', 'no-load.txt',
        'modules/vendor/lib/modules/fixture.ko',
        'vendor_ramdisk/lib/modules/fixture.ko',
        'vendor_ramdisk/lib/modules/modules.load.recovery',
        'vendor_patch/fstab', 'ramdisk/config', 'custom-device-helper.sh',
    }
    excluded = {'tests/unwanted.py', 'config', 'build-info.json', 'README.md',
                '.github/workflows/unwanted.yml', '.git/config',
                'ramdisk/placeholder', 'SHA256SUMS'}
    for name in sorted(runtime | excluded):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((name + '\n').encode() * 3)
    output = Path(td) / 'test.zip'
    subprocess.run([sys.executable, '-c', program, str(root), str(output)], check=True)
    with zipfile.ZipFile(output) as z:
        assert z.testzip() is None
        assert set(z.namelist()) == runtime | {'SHA256SUMS'}
        lines = z.read('SHA256SUMS').decode().splitlines()
        assert len(lines) == len(runtime)
        for line in lines:
            digest, name = line.split('  ', 1)
            assert hashlib.sha256(z.read(name)).hexdigest() == digest
            assert z.read(name) == (root / name).read_bytes()
    (root / 'tools/escape').symlink_to(root.parent / 'outside')
    result = subprocess.run([sys.executable, '-c', program, str(root), str(output)],
                            text=True, capture_output=True)
    assert result.returncode != 0
    assert 'non-regular package entry' in result.stderr
print('PASS: recovery tools, module helpers and ramdisk payloads retained with complete checksums')
