#!/usr/bin/env python3
"""Verify PE architecture, DLL import closure, plugins, and bundled notices."""
import argparse
import json
import os
from pathlib import Path
import re
import struct


class PE:
    def __init__(self, path):
        self.path = path
        self.data = path.read_bytes()
        if self.data[:2] != b'MZ':
            raise ValueError(f'{path}: missing DOS/PE header')
        offset = self.unpack('<I', 0x3c)[0]
        if self.data[offset:offset + 4] != b'PE\0\0':
            raise ValueError(f'{path}: missing PE signature')
        self.machine, count = self.unpack('<HH', offset + 4)
        optional_size = self.unpack('<H', offset + 20)[0]
        optional = offset + 24
        magic = self.unpack('<H', optional)[0]
        if magic not in (0x10b, 0x20b):
            raise ValueError(f'{path}: invalid optional PE header')
        self.image_base = self.unpack('<I' if magic == 0x10b else '<Q', optional + (28 if magic == 0x10b else 24))[0]
        self.header_size = self.unpack('<I', optional + 60)[0]
        self.subsystem_version = self.unpack('<HH', optional + 48)
        directory_start = optional + (96 if magic == 0x10b else 112)
        directory_count = self.unpack('<I', directory_start - 4)[0]
        self.directories = [self.unpack('<II', directory_start + 8 * index) for index in range(min(directory_count, 16))]
        self.sections = []
        for index in range(count):
            section = optional + optional_size + 40 * index
            size, rva, raw_size, raw = self.unpack('<IIII', section + 8)
            self.sections.append((rva, max(size, raw_size), raw, raw_size))

    def unpack(self, fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(self.data):
            raise ValueError(f'{self.path}: truncated PE data')
        return struct.unpack_from(fmt, self.data, offset)

    def file_offset(self, rva):
        if rva < self.header_size:
            return rva
        for start, size, raw, raw_size in self.sections:
            if start <= rva < start + size and rva - start < raw_size:
                return raw + rva - start
        raise ValueError(f'{self.path}: invalid PE RVA {rva:#x}')

    def dll_name(self, rva):
        offset = self.file_offset(rva)
        end = self.data.find(b'\0', offset, offset + 512)
        if end < 0:
            raise ValueError(f'{self.path}: invalid DLL import name')
        name = self.data[offset:end].decode('ascii').lower()
        if not name.endswith('.dll') or '/' in name or '\\' in name:
            raise ValueError(f'{self.path}: invalid DLL import {name}')
        return name

    def imports(self):
        result = set()
        for index, width in ((1, 20), (13, 32)):
            if index >= len(self.directories):
                continue
            rva, size = self.directories[index]
            if not rva:
                continue
            offset = self.file_offset(rva)
            for position in range(0, size, width):
                fields = self.unpack('<' + 'I' * (width // 4), offset + position)
                if not any(fields):
                    break
                name_rva = fields[3] if index == 1 else fields[1]
                if index == 13 and not fields[0] & 1:
                    name_rva -= self.image_base
                result.add(self.dll_name(name_rva))
        return sorted(result)


def pe_machine(path):
    return PE(path).machine


def system_directory(architecture):
    root = os.environ.get('SystemRoot')
    if not root:
        raise ValueError('Run on Windows, or provide --system-dir for fixture validation')
    native = os.environ.get('PROCESSOR_ARCHITEW6432', os.environ.get('PROCESSOR_ARCHITECTURE', '')).upper()
    folder = 'SysWOW64' if architecture == 'x86' and native in ('AMD64', 'ARM64') else 'System32'
    return Path(root) / folder


def check_package(directory, architecture, system_dir=None):
    expected = {'x86': 0x14c, 'x64': 0x8664}[architecture]
    binaries = sorted(path for path in directory.rglob('*') if path.suffix.lower() in ('.exe', '.dll'))
    uninstallers = [path for path in binaries if re.fullmatch(r'unins\d{3}\.exe', path.name, re.IGNORECASE)]
    for path in uninstallers:
        if pe_machine(path) != 0x14c:
            raise ValueError(f'{path}: pinned Inno Setup6 uninstaller is expected to be x86')
    binaries = [path for path in binaries if path not in uninstallers]
    if not binaries:
        raise ValueError('no deployed PE files')
    local = {path.name.lower(): path for path in directory.iterdir() if path.is_file()}
    required = ('consoleview.exe', 'Qt5Core.dll', 'Qt5Gui.dll', 'Qt5Widgets.dll', 'Qt5Multimedia.dll',
                'Qt5MultimediaWidgets.dll', 'Qt5Svg.dll', 'platforms/qwindows.dll', 'platforms/qoffscreen.dll',
                'mediaservice/dsengine.dll', 'mediaservice/wmfengine.dll', 'audio/qtaudio_windows.dll', 'audio/qtaudio_wasapi.dll',
                'vcruntime140.dll', 'msvcp140.dll', 'qt.conf', 'qt-runtime-version.txt', 'LICENSE.txt',
                'THIRD-PARTY-NOTICES.txt', 'QT-SOURCE-OFFER.txt', 'REPLACING-QT.txt', 'WINDOWS-INSTALL.txt',
                'licenses/LICENSE.LGPL3', 'licenses/LICENSE.GPL3')
    for name in required:
        if not (directory / name).is_file():
            raise ValueError(f'missing deployed dependency/notice: {name}')
    if (directory / 'qt-runtime-version.txt').read_text().strip() != '5.15.2':
        raise ValueError('Qt source offer does not match the bundled SDK version')
    if '[Paths]\nPrefix=.\nPlugins=.' not in (directory / 'qt.conf').read_text():
        raise ValueError('Qt plugin paths are not relative to the application')
    system_dir = system_dir or system_directory(architecture)
    system = {path.name.lower(): path for path in system_dir.iterdir() if path.is_file()}
    forbidden = ('qt5charts', 'qt5datavisualization', 'qt5virtualkeyboard', 'qt5quick3d', 'qt5webengine')
    imports = {}
    for path in binaries:
        image = PE(path)
        if image.machine != expected:
            raise ValueError(f'{path}: wrong PE architecture for {architecture}')
        if path.name.lower().startswith(forbidden):
            raise ValueError(f'unexpected unapproved Qt module: {path.name}')
        if path.name.lower() == 'consoleview.exe' and image.subsystem_version > (10, 0):
            raise ValueError('application PE subsystem requires newer than Windows10')
        imports[str(path.relative_to(directory))] = image.imports()
        neighbors = {item.name.lower(): item for item in path.parent.iterdir() if item.is_file()}
        for name in image.imports():
            provider = neighbors.get(name) or local.get(name)
            # API-set names resolve through the Windows10 loader rather than one DLL per contract.
            if provider is None and name.startswith(('api-ms-win-', 'ext-ms-win-')):
                continue
            if provider is None and name.startswith(('qt5', 'msvcp', 'vcruntime', 'concrt')):
                raise ValueError(f'{path}: non-system dependency is not app-local: {name}')
            provider = provider or system.get(name)
            if provider is None:
                raise ValueError(f'{path}: missing imported DLL: {name}')
            if pe_machine(provider) != expected:
                raise ValueError(f'{path}: imported DLL has wrong architecture: {name}')
    print(json.dumps({'architecture': architecture, 'minimum_windows': '10', 'qt_version': '5.15.2',
                      'pe_files': len(binaries), 'inno_x86_uninstallers': len(uninstallers), 'imports': imports}, indent=2))
    print(f'PASS: {len(binaries)} PE files match {architecture}; DLL imports, camera/audio plugins, and notices are complete.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('architecture', choices=('x86', 'x64'))
    parser.add_argument('--system-dir', type=Path)
    args = parser.parse_args()
    check_package(args.directory, args.architecture, args.system_dir)
