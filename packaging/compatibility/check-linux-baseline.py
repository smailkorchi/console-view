#!/usr/bin/env python3
"""Check ELF architecture and reject libc/ABI requirements above the release baseline."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--libc', choices=['glibc', 'musl'], default='glibc')
parser.add_argument('--arch', choices=['x86_64', 'arm64', 'i386', 'armhf'])
args = parser.parse_args()
machines = {'x86_64': ('ELF64', 'Advanced Micro Devices X86-64'), 'arm64': ('ELF64', 'AArch64'), 'i386': ('ELF32', 'Intel 80386'), 'armhf': ('ELF32', 'ARM')}
count = 0
for path in sorted(args.directory.rglob('*')):
    if not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    symbols = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
    versions = {tuple(int(part) for part in value.split('.')) for value in re.findall(r'GLIBC_(\d+\.\d+)', symbols)}
    if args.libc == 'musl' and versions:
        raise SystemExit(f'{path}: glibc symbols found in a musl package')
    if args.libc == 'glibc' and any(item > (2, 31) for item in versions):
        raise SystemExit(f'{path}: GLIBC requirement exceeds 2.31: {sorted(versions)}')
    cpp = {tuple(int(part) for part in value.split('.')) for value in re.findall(r'GLIBCXX_(\d+\.\d+\.\d+)', symbols)}
    if args.libc == 'glibc' and any(item > (3, 4, 28) for item in cpp):
        raise SystemExit(f'{path}: libstdc++ requirement exceeds GCC10: {sorted(cpp)}')
    if args.arch:
        header = subprocess.check_output(['readelf', '--file-header', str(path)], text=True)
        elf_class, machine = machines[args.arch]
        if not re.search(r'Class:\s+'+elf_class+r'\b', header) or not re.search(r'Machine:\s+'+re.escape(machine)+r'\s*$', header, re.M):
            raise SystemExit(f'{path}: ELF architecture does not match {args.arch}')
    count += 1
if not count:
    raise SystemExit('No bundled ELF files found')
print(f'PASS: {count} bundled ELF files match {args.arch or "requested"} {args.libc} baseline' + (' (GLIBC <= 2.31, GLIBCXX <= 3.4.28).' if args.libc == 'glibc' else ' (no glibc symbols).'))
