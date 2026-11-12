"""Exercise ZIP naming and provenance without compiling or using the network."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


scripts = Path(__file__).resolve().parents[1]
bot = (scripts / 'bot.sh').read_text()
status_program = bot[bot.index('ksu_status="No"'):bot.index('\ncaption=')]


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    commands = root / 'bin'
    commands.mkdir()
    executable(commands / 'curl', '#!/bin/sh\nexit 99\n')
    executable(commands / 'git', '''#!/bin/sh
case "$1" in
    rev-parse) printf '1111111111111111111111111111111111111111\\n' ;;
    status) exit 0 ;;
    *) exit 99 ;;
esac
''')
    executable(commands / 'ccache', '#!/bin/sh\nexit 0\n')
    executable(commands / 'make', '''#!/bin/sh
set -eu
case " $* " in
    *" vendor/bangkk_defconfig "*)
        mkdir -p out
        cp "$TEST_CONFIG" out/.config
        ;;
    *)
        mkdir -p out/arch/arm64/boot
        printf 'fixture Image\\n' > out/arch/arm64/boot/Image
        ;;
esac
''')
    toolchain = root / 'toolchain'
    (toolchain / 'bin').mkdir(parents=True)
    for tool in ('clang', 'ld.lld', 'llvm-ar', 'llvm-nm', 'llvm-objcopy',
                 'llvm-objdump', 'llvm-readelf', 'llvm-strip', 'llvm-size'):
        executable(toolchain / 'bin' / tool,
                   '#!/bin/sh\nprintf "fixture toolchain 22\\n"\n')
    archive = root / 'toolchain.tar'
    archive.write_bytes(b'fixture toolchain archive')
    environment = dict(os.environ, PATH=f'{commands}:/usr/bin:/bin',
                       TC_DIR=str(toolchain), CLANG_REV='fixture',
                       CLANG_VERSION='fixture', CLANG_URL='https://invalid.example/toolchain.tar',
                       CLANG_SHA256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                       SKIP_UPLOAD='1', JOBS='1', MIN_FREE_GB='0')
    subprocess.run(['python3', str(scripts / 'toolchain.py'), 'write',
                    str(toolchain), str(archive)], env=environment, check=True)
    template = root / 'template'
    template.mkdir()
    (template / 'anykernel.sh').write_text('# fixture installer\n')
    environment['AK3_DIR'] = str(template)
    cases = [(branch, ksu, susfs) for branch in ('seventeen', 'eevdf')
             for ksu, susfs in ((False, False), (False, True), (True, False), (True, True))]
    cases += [(None, False, False), ('feature/eevdf', False, False)]
    for number, (branch, ksu, susfs) in enumerate(cases):
        work = root / str(number)
        (work / 'arch/arm64/configs/vendor').mkdir(parents=True)
        (work / 'Makefile').touch()
        (work / 'arch/arm64/configs/vendor/bangkk_defconfig').touch()
        (work / 'arch/arm64/configs/moto.config').touch()
        config = work / 'fixture.config'
        config.write_text(('CONFIG_KSU=y\n' if ksu else '# CONFIG_KSU is not set\n') +
                          ('CONFIG_KSU_SUSFS=y\n' if ksu and susfs else
                           'CONFIG_KSU_MANUAL_HOOK=y\n' if ksu else ''))
        outputs = work / 'outputs'
        env = dict(environment, TEST_CONFIG=str(config), GITHUB_OUTPUT=str(outputs),
                   BUILD_KSU=str(ksu).lower(), BUILD_SUSFS=str(susfs).lower())
        env.pop('KERNEL_BRANCH', None)
        if branch is not None:
            env['KERNEL_BRANCH'] = branch
        result = subprocess.run(['bash', str(scripts / 'sashimi.sh'), '-v', 'bangkk'],
                                cwd=work, env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        values = dict(line.split('=', 1) for line in outputs.read_text().splitlines())
        assert values['build_success'] == 'true'
        prefix = 'Sashimi' + ('-eevdf' if branch == 'eevdf' else '')
        prefix += '-ksu' if ksu else ''
        prefix += '-susfs' if ksu and susfs else ''
        name = values['zip_file']
        assert re.fullmatch(re.escape(prefix) + r'-\d{8}-\d{4}-bangkk\.zip', name), name
        info = json.loads((work / 'out/build-info.json').read_text())
        assert info['kernel_branch'] == branch
        assert info['sha256']['.config'] == hashlib.sha256(config.read_bytes()).hexdigest()
        with zipfile.ZipFile(work / name) as package:
            assert package.read('Image') == b'fixture Image\n'
            assert not {'config', '.config', 'kernel.config', 'build-info.json'} & set(package.namelist())
        statuses = subprocess.check_output(
            ['bash', '-c', status_program + '\nprintf "%s %s" "$ksu_status" "$susfs_status"'],
            env=dict(env, zip_file=name), text=True)
        assert statuses == f'{"Yes" if ksu else "No"} {"Yes" if ksu and susfs else "No"}', statuses

print(f'PASS: {len(cases)} offline builds; branch names, bot flags and external metadata')
