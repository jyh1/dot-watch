#!/usr/bin/env python3
"""Fail a device build if the phone or embedded Watch app lost its app icon."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def verify(app):
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    name = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName')
    if not name:
        raise ValueError(f'{app.name}: missing primary app icon metadata')
    assets = json.loads(subprocess.check_output(
        ['xcrun', 'assetutil', '--info', str(app / 'Assets.car')], text=True))
    if not any(a.get('Name') == name and a.get('AssetType') == 'Icon Image' for a in assets):
        raise ValueError(f'{app.name}: app icon has no compiled image')
    print(f'{app.name}: compiled app icon verified')


if __name__ == '__main__':
    try:
        phone = Path(sys.argv[1])
        watches = list((phone / 'Watch').glob('*.app'))
        if len(watches) != 1:
            raise ValueError('Expected one embedded Watch app')
        verify(phone)
        verify(watches[0])
    except (IndexError, OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'Icon verification failed: {error}')
