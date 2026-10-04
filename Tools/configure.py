#!/usr/bin/env python3
"""Generate build metadata and assets; local inputs never need source edits."""
import argparse
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def configuration(path=None):
    config = json.loads((ROOT / 'Config.example.json').read_text())
    if path:
        path = Path(path).expanduser().resolve()
        local = json.loads(path.read_text())
        unknown = local.keys() - config.keys()
        if unknown:
            raise ValueError('Unknown configuration keys: ' + ', '.join(sorted(unknown)))
        config.update(local)
    for key in ('app_name', 'bundle_id', 'development_team', 'signing', 'provisioning_profile', 'accent_hex', 'default_agent_page', 'url_scheme', 'widget_kind'):
        if not isinstance(config[key], str) or any(ord(c) < 32 for c in config[key]):
            raise ValueError(f'{key} must be plain text')
    if not config['app_name'].strip() or len(config['app_name']) > 40:
        raise ValueError('app_name must be 1–40 characters')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', config['bundle_id']):
        raise ValueError('bundle_id must be a reverse-DNS identifier')
    if config['development_team'] and not re.fullmatch(r'[A-Z0-9]{10}', config['development_team']):
        raise ValueError('development_team must be a 10-character Apple team ID')
    if config['signing'] not in ('automatic', 'manual'):
        raise ValueError('signing must be automatic or manual')
    if config['signing'] == 'manual' and not config['provisioning_profile']:
        raise ValueError('manual signing requires provisioning_profile')
    if not re.fullmatch(r'[0-9a-fA-F]{6}', config['accent_hex']):
        raise ValueError('accent_hex must contain six hexadecimal digits')
    if not re.fullmatch(r'[a-z][a-z0-9+.-]*', config['url_scheme']):
        raise ValueError('url_scheme must be a lowercase URL scheme')
    if not config['widget_kind']:
        raise ValueError('widget_kind cannot be empty')
    aliases = config['siri_aliases']
    if not isinstance(aliases, list) or len(aliases) > 3 or any(not isinstance(a, str) or not a.strip() or len(a)>40 or any(ord(c)<32 for c in a) for a in aliases):
        raise ValueError('siri_aliases must contain at most three short names')
    for key in ('app_icon', 'avatar'):
        if config[key] is not None:
            if not isinstance(config[key], str):
                raise ValueError(f'{key} must be a PNG path or null')
            source = Path(config[key]).expanduser()
            source = source if source.is_absolute() else (path.parent if path else ROOT) / source
            if not source.is_file() or source.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
                raise ValueError(f'{key} must point to a PNG file')
            config[key] = str(source.resolve())
    return config

def generate(config, destination):
    destination.mkdir(parents=True, exist_ok=True)
    name, bundle = config['app_name'], config['bundle_id']
    common = dict(DotAppName=name, DotAccentHex=config['accent_hex'], DotURLScheme=config['url_scheme'],
                  DotKeychainService=bundle+'.account', DotWidgetKind=config['widget_kind'])
    targets = {}
    for target, suffix in [('DotWatchPhone',''),('DotWatchWatch','.watchkitapp'),('DotWidget','.watchkitapp.widgets'),('DotWatchTests','.tests')]:
        settings = dict(PRODUCT_BUNDLE_IDENTIFIER=bundle+suffix, CODE_SIGN_STYLE=config['signing'].capitalize())
        if config['development_team']:
            settings['DEVELOPMENT_TEAM'] = config['development_team']
        if config['signing'] == 'manual':
            settings['PROVISIONING_PROFILE_SPECIFIER'] = config['provisioning_profile']
        targets[target] = {'settings': {'base': settings}}
        if target == 'DotWatchTests':
            continue
        props = dict(common, CFBundleDisplayName=name)
        if target in ('DotWatchPhone', 'DotWatchWatch'):
            props.update(DotDefaultAgentPage=config['default_agent_page'],
                NSMicrophoneUsageDescription=f'Talk to {name} in a voice call.',
                CFBundleURLTypes=[dict(CFBundleURLName=bundle+'.call', CFBundleURLSchemes=[config['url_scheme']])],
                INAlternativeAppNames=[{'INAlternativeAppName': a} for a in dict.fromkeys(config['siri_aliases']) if a.casefold()!=name.casefold()])
        if target == 'DotWatchWatch':
            props['WKCompanionAppBundleIdentifier'] = bundle
        targets[target]['info'] = {'properties': props}
    # JSON is valid YAML and safely quotes arbitrary names and paths.
    (destination/'Settings.yml').write_text(json.dumps({'targets':targets}, indent=2)+'\n')
    assets = destination/'Assets.xcassets'
    assets.mkdir(exist_ok=True)
    (assets/'Contents.json').write_text(json.dumps({'info': {'author':'xcode','version':1}}))
    for key, folder, filename in [('app_icon','DotIcon.appiconset','AppIcon.png'),('avatar','Dot.imageset','Dot.png')]:
        target=assets/folder
        target.mkdir(exist_ok=True)
        source=Path(config[key]) if config[key] else ROOT/'Branding/Default'/('AppIcon.png' if key=='app_icon' else 'Avatar.png')
        shutil.copyfile(source,target/filename)
        item={'filename':filename,'idiom':'universal'}
        if key=='app_icon': item.update(platform='ios', size='1024x1024')
        else: item['scale']='1x'
        # Universal single-size app icons work for both current iOS and watchOS.
        if key=='app_icon': item.pop('platform')
        (target/'Contents.json').write_text(json.dumps({'images':[item],'info':{'author':'xcode','version':1}},indent=2))
    widget=destination/'Widget'
    widget.mkdir(exist_ok=True)
    shutil.copyfile(assets/'Dot.imageset/Dot.png',widget/'Dot.png')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,help='Optional private JSON overrides (relative image paths resolve beside it)')
    args=parser.parse_args()
    path=args.config or (ROOT/'Config.local.json' if (ROOT/'Config.local.json').exists() else None)
    try:
        generate(configuration(path), ROOT/'Generated')
    except (ValueError, OSError) as error:
        parser.exit(1,f'Configuration failed: {error}\n')
    print('Generated build settings and assets. Run xcodegen generate next.')

if __name__=='__main__': main()
