#!/usr/bin/env python3
"""Bundle replaceable Qt ABI dependencies; retain host media, graphics and libc."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import quote
from urllib.request import urlopen

directory = Path(sys.argv[1])
pending = [directory/'bin/consoleview'] + list((directory/'plugins').rglob('*.so'))
seen = set()
records = []
external = set()
environment = dict(__import__('os').environ, LD_LIBRARY_PATH=str(directory/'lib'))
licenses = directory/'licenses'/'bundled-packages'
licenses.mkdir(parents=True, exist_ok=True)

def package_record(path):
    if shutil.which('dpkg-query'):
        owner = subprocess.check_output(['dpkg-query', '-S', path], text=True).splitlines()[0].rsplit(': ', 1)[0]
        detail = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}\t${Version}\t${source:Package}\t${source:Version}', owner], text=True).split('\t')
        package, version, source, source_version = detail
        source, source_version = source or package, source_version or version
        notice = Path('/usr/share/doc')/package/'copyright'
        if not notice.is_file():
            raise SystemExit(f'Missing copyright notice for {package}')
        shutil.copyfile(notice, licenses/(package+'.copyright'))
        return {'package': package, 'version': version, 'source_package': source, 'source_version': source_version,
                'source_url': f'https://sources.debian.org/src/{quote(source, safe="")}/{quote(source_version, safe="")}/'}
    if shutil.which('apk'):
        owner = subprocess.check_output(['apk', 'info', '--who-owns', path], text=True).strip().split()[-1]
        package = re.sub(r'-\d[^/]*$', '', owner)
        metadata = next((dict(line.split(':', 1) for line in block.splitlines() if ':' in line) for block in Path('/lib/apk/db/installed').read_text().split('\n\n') if f'P:{package}\n' in block+'\n'), None)
        if not metadata or not metadata.get('c'):
            raise SystemExit(f'Missing exact Alpine source commit for {package}')
        source, version = metadata.get('o', package), metadata['V']
        repository = 'community' if source.startswith('qt5-') or source == 'double-conversion' else 'main'
        upstream_version = version.split('-r')[0]
        license_url = None
        if source == 'icu':
            license_url = f'https://raw.githubusercontent.com/unicode-org/icu/release-{upstream_version.replace(".", "-")}/LICENSE'
            data_files = list((Path('/usr/share/icu')/upstream_version).glob('icudt*.dat'))
            if not data_files:
                raise SystemExit(f'Missing Alpine ICU data for {upstream_version}')
            (directory/'share/icu').mkdir(parents=True, exist_ok=True)
            for data in data_files:
                shutil.copyfile(data, directory/'share/icu'/data.name)
        elif source == 'pcre2':
            license_url = f'https://raw.githubusercontent.com/PCRE2Project/pcre2/pcre2-{upstream_version}/LICENCE'
        elif source == 'double-conversion':
            license_url = f'https://raw.githubusercontent.com/google/double-conversion/v{upstream_version}/LICENSE'
        elif source == 'libjpeg-turbo':
            license_url = f'https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/{upstream_version}/LICENSE.md'
            with urlopen(f'https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/{upstream_version}/README.ijg', timeout=60) as response:
                (licenses/(source+'.README.ijg')).write_bytes(response.read())
        if license_url and not (licenses/(source+'.LICENSE')).exists():
            with urlopen(license_url, timeout=60) as response:
                (licenses/(source+'.LICENSE')).write_bytes(response.read())
        return {'package': package, 'version': version, 'source_package': source, 'license': metadata.get('L'),
                'source_commit': metadata['c'],
                'source_url': f'https://gitlab.alpinelinux.org/alpine/aports/-/tree/{metadata["c"]}/{repository}/{quote(source, safe="")}',
                'source_archive': 'https://distfiles.alpinelinux.org/distfiles/v3.22/'}
    raise SystemExit('Cannot record exact source packages without dpkg-query or apk')

while pending:
    binary = pending.pop()
    if binary in seen:
        continue
    seen.add(binary)
    dependencies = subprocess.check_output(['ldd', str(binary)], text=True, env=environment, stderr=subprocess.STDOUT)
    if 'not found' in dependencies:
        raise SystemExit(f'Unresolved dependency in {binary}:\n{dependencies}')
    for soname, resolved in re.findall(r'^\s*(\S+) => (\S+)', dependencies, re.M):
        if not soname.startswith(('libQt5', 'libicu', 'libdouble-conversion', 'libpcre2-16', 'libjpeg')):
            external.add(soname)
            continue
        target = directory/'lib'/soname
        if not target.exists():
            record = package_record(resolved)
            shutil.copyfile(resolved, target)
            pending.append(target)
            records.append(dict(library=soname, **record))
(directory/'bundled-libraries.json').write_text(json.dumps(records, indent=2)+'\n')
(directory/'host-library-dependencies.txt').write_text('\n'.join(sorted(external))+'\n')
print(f'Bundled {len(records)} dynamically linked Qt/ICU ABI libraries with exact package/source records.')
