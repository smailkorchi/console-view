#!/usr/bin/env python3
"""Check Intel deployment metadata and dependency closure, without lowering targets."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

MACHO_MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
DYLIB_COMMANDS = {
    'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
    'LC_LOAD_UPWARD_DYLIB',
}
SYSTEM_PREFIXES = ('/usr/lib/', '/System/Library/')


def version(value):
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError(f'invalid OS version: {value}')
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def load_commands(text):
    for block in re.split(r'(?m)^Load command \d+\s*$', text)[1:]:
        name = re.search(r'(?m)^\s*cmd (LC_\S+)\s*$', block)
        if name:
            yield name.group(1), block


def minimum_versions(commands):
    results = []
    for name, command in load_commands(commands):
        if name == 'LC_VERSION_MIN_MACOSX':
            match = re.search(r'\bversion (\d+(?:\.\d+){1,2})', command)
        elif name == 'LC_BUILD_VERSION':
            platform = re.search(r'\bplatform (\S+)', command)
            if not platform or platform.group(1) not in ('1', 'macos', 'MACOS'):
                raise ValueError('non-macOS Mach-O platform')
            match = re.search(r'\bminos (\d+(?:\.\d+){1,2})', command)
        else:
            continue
        if not match:
            raise ValueError('missing minimum OS in load command')
        results.append(match.group(1))
    if not results:
        raise ValueError('missing macOS minimum-version load command')
    return results


def command_paths(commands, names, field):
    results = []
    for name, block in load_commands(commands):
        if name in names:
            match = re.search(rf'(?m)^\s*{field} (.+) \(offset \d+\)\s*$', block)
            if not match:
                raise ValueError(f'{name}: missing {field}')
            results.append((name, match.group(1)))
    return results


def is_macho(path):
    if not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MACHO_MAGIC


def is_inside(path, bundle):
    return path.resolve() == bundle or bundle in path.resolve().parents


def expand_path(value, loader, executable):
    for prefix, base in (('@loader_path', loader.parent),
                         ('@executable_path', executable.parent)):
        if value == prefix or value.startswith(prefix + '/'):
            return (base / value[len(prefix):].lstrip('/')).resolve()
    if value.startswith('/'):
        return Path(value).resolve()
    raise ValueError(f'unsupported dyld path: {value}')


def check_bundle(bundle, maximum, imports_report=None):
    bundle = bundle.resolve(strict=True)
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if version(info.get('LSMinimumSystemVersion', '0')) > version(maximum):
        raise ValueError('Info.plist minimum OS exceeds the requested baseline')
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    if not is_inside(executable, bundle) or not is_macho(executable):
        raise ValueError('missing bundle Mach-O executable')
    images = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            if not is_inside(path, bundle) or not path.exists():
                raise ValueError(f'{path}: dangling symlink or target outside bundle')
            continue
        if not is_macho(path):
            continue
        arches = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
        if 'x86_64' not in arches:
            raise ValueError(f'{path}: no x86_64 slice ({arches})')
        commands = subprocess.check_output(['otool', '-arch', 'x86_64', '-l', str(path)], text=True)
        minimums = minimum_versions(commands)
        if any(version(item) > version(maximum) for item in minimums):
            raise ValueError(f'{path}: minimum OS {minimums} exceeds {maximum}')
        for name, _ in load_commands(commands):
            if version(maximum) < version('10.14') and name in {
                    'LC_DYLD_CHAINED_FIXUPS', 'LC_DYLD_EXPORTS_TRIE'}:
                raise ValueError(f'{path}: {name} requires a newer dyld')
        images[path.resolve()] = commands
        print(f'{path.relative_to(bundle)}: x86_64, minimum {", ".join(minimums)}')
    if not images:
        raise ValueError('bundle contains no Mach-O files')
    main_rpaths = command_paths(images[executable.resolve()], {'LC_RPATH'}, 'path')
    system_dependencies = set()
    for path, commands in images.items():
        rpaths = [expand_path(value, path, executable)
                  for _, value in command_paths(commands, {'LC_RPATH'}, 'path')]
        rpaths += [expand_path(value, executable, executable) for _, value in main_rpaths]
        for rpath in rpaths:
            if not is_inside(rpath, bundle) and not str(rpath).startswith(SYSTEM_PREFIXES):
                raise ValueError(f'{path}: external runtime search path {rpath}')
        for command, dependency in command_paths(commands, DYLIB_COMMANDS, 'name'):
            if dependency.startswith(SYSTEM_PREFIXES):
                system_dependencies.add((command, dependency))
                continue
            if dependency.startswith('@rpath/'):
                candidates = [base / dependency[len('@rpath/'):] for base in rpaths]
                resolved = next((item.resolve() for item in candidates if item.is_file()), None)
                if resolved is None:
                    raise ValueError(f'{path}: unresolved dependency {dependency}')
            else:
                resolved = expand_path(dependency, path, executable)
            if not is_inside(resolved, bundle) or resolved not in images:
                raise ValueError(f'{path}: dependency is not a bundled Mach-O: {dependency}')
    print(f'PASS: {len(images)} Mach-O files meet macOS {maximum} deployment metadata and dependency closure.')
    print('System library imports (availability on the target OS still requires target-runtime verification):')
    for command, dependency in sorted(system_dependencies):
        print(f'  {command}: {dependency}')
    if imports_report:
        with imports_report.open('w') as report:
            report.write('Intel undefined imports; an inventory, not a High Sierra symbol-availability certificate.\n')
            for path in images:
                report.write(f'\n{path.relative_to(bundle)}\n')
                report.write(subprocess.check_output(
                    ['nm', '-arch', 'x86_64', '-u', '-m', str(path)], text=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--maximum', default='10.13')
    parser.add_argument('--imports-report', type=Path)
    args = parser.parse_args()
    check_bundle(args.bundle, args.maximum, args.imports_report)
