#!/usr/bin/env python3
"""Build pinned genuine NetEq C ABI XCFramework; no app/audio/network runtime."""
from pathlib import Path
import argparse, fcntl, hashlib, json, os, shutil, subprocess, sys, tarfile, urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get('DOT_NETEQ_CACHE', str(ROOT / '.native-neteq-cache'))).resolve()
WEBRTC = 'ddd3e1dc172f322356ca91cb764d57c7b81ed282'
OPUS = ('https://codeload.github.com/xiph/opus/tar.gz/refs/tags/v1.6.1', 'bf0b97ec7a65890b8db90ef94c4d6c18de12584c3085031953a10986f5917745')
ABSEIL = ('https://codeload.github.com/abseil/abseil-cpp/tar.gz/refs/tags/20260107.1', '4314e2a7cbac89cac25a2f2322870f343d81579756ceff7f431803c2c9090195')
PROFILES = [
    ('macos', 'Darwin', 'macosx', 'arm64', '26.0'),
    ('ios', 'iOS', 'iphoneos', 'arm64', '26.0'),
    ('ios-simulator', 'iOS', 'iphonesimulator', 'arm64', '26.0'),
    ('watchos', 'watchOS', 'watchos', 'arm64;arm64_32', '26.0'),
    ('watchos-simulator', 'watchOS', 'watchsimulator', 'arm64', '26.0'),
]
def command(args, log=None):
    if log:
        with open(log, 'w') as output:
            result = subprocess.run([str(x) for x in args], stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print(Path(log).read_text()[-10000:], file=sys.stderr)
            raise RuntimeError('Native build failed; log: ' + str(log))
    else: subprocess.run([str(x) for x in args], check=True)
def download_extract(spec, name):
    url, checksum = spec
    dest = CACHE / 'sources' / name
    if dest.exists() and (dest / '.dot-source-sha256').exists() and (dest / '.dot-source-sha256').read_text().strip() == checksum: return dest
    archive = CACHE / (name + '.tar.gz')
    if not archive.exists():
        temp = archive.with_suffix('.download')
        urllib.request.urlretrieve(url, temp); temp.rename(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum: raise RuntimeError('Source archive checksum mismatch: ' + name)
    staging = CACHE / 'sources' / (name + '.extract')
    if staging.exists(): shutil.rmtree(staging)
    staging.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            resolved = (staging / member.name).resolve()
            if staging.resolve() not in resolved.parents: raise RuntimeError('Unsafe source archive path')
        tar.extractall(staging)
    children = list(staging.iterdir())
    if len(children) != 1 or not children[0].is_dir(): raise RuntimeError('Unexpected source archive layout')
    if dest.exists(): shutil.rmtree(dest)
    children[0].rename(dest); staging.rmdir()
    (dest / '.dot-source-sha256').write_text(checksum + '\n'); return dest

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--force', action='store_true'); parser.add_argument('--jobs', type=int, default=min(6, os.cpu_count() or 2)); args = parser.parse_args()
    if sys.platform != 'darwin': raise RuntimeError('NetEq Apple XCFramework build requires macOS and Xcode with iOS/watchOS SDKs.')
    CACHE.mkdir(parents=True, exist_ok=True)
    lock_file = open(CACHE / 'build.lock', 'a'); fcntl.flock(lock_file, fcntl.LOCK_EX)
    inputs = [*sorted((ROOT / 'Native').rglob('*')), Path(__file__)]
    digest = hashlib.sha256()
    for file in inputs:
        if file.is_file(): digest.update(file.relative_to(ROOT).as_posix().encode()); digest.update(file.read_bytes())
    tool_info = subprocess.check_output(['xcodebuild', '-version'])
    sdk_info = {sdk: subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-version']).decode().strip() for _,_,sdk,_,_ in PROFILES}
    digest.update(tool_info); digest.update(json.dumps(sdk_info, sort_keys=True).encode()); digest.update(WEBRTC.encode())
    fingerprint = digest.hexdigest()
    package = CACHE / 'packages' / fingerprint / 'NetEqNative.xcframework'
    vendor = ROOT / 'Vendor' / 'NetEqNative' / 'NetEqNative.xcframework'
    if not args.force and (package / 'Info.plist').exists() and vendor.exists() and vendor.resolve() == package:
        print('NetEq native dependency is cached (all Apple slices).'); return
    (CACHE / 'sources').mkdir(exist_ok=True)
    tools = CACHE / 'tools-env'
    if not (tools / 'bin' / 'cmake').exists():
        command([sys.executable, '-m', 'venv', tools])
        command([tools / 'bin' / 'pip', 'install', 'cmake==4.4.4', 'ninja==1.13.2'], CACHE / 'tools-install.log')
    webrtc = CACHE / 'sources' / 'webrtc'
    if not (webrtc / '.git').exists():
        webrtc.mkdir(exist_ok=True); command(['git','init',webrtc], CACHE / 'source-init.log')
        command(['git','-C',webrtc,'remote','add','origin','https://webrtc.googlesource.com/src'])
    try: revision = subprocess.check_output(['git','-C',webrtc,'rev-parse','HEAD'],stderr=subprocess.DEVNULL).decode().strip()
    except subprocess.CalledProcessError: revision = ''
    if revision != WEBRTC:
        command(['git','-C',webrtc,'fetch','--depth=1','origin',WEBRTC], CACHE / 'source-fetch.log')
        command(['git','-C',webrtc,'checkout','--detach',WEBRTC], CACHE / 'source-checkout.log')
    opus = download_extract(OPUS, 'opus'); abseil = download_extract(ABSEIL, 'abseil')
    link = webrtc / 'third_party' / 'opus' / 'src'; link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink(): link.unlink()
    if not link.exists(): link.symlink_to(os.path.relpath(opus, link.parent))
    generated = CACHE / 'generated'; (generated / 'experiments').mkdir(parents=True, exist_ok=True)
    command([sys.executable, webrtc / 'experiments' / 'field_trials.py', 'header', '--no-validation', '--output', generated / 'experiments' / 'registered_field_trials.h'])
    cmake = tools / 'bin' / 'cmake'; libraries = []
    for name, system, sdk, arches, minimum in PROFILES:
        print('Building genuine NetEq: ' + name + ' (' + arches + ')', flush=True)
        build = CACHE / 'build' / fingerprint / name; build.mkdir(parents=True, exist_ok=True)
        mapping = '-ffile-prefix-map=' + str(ROOT) + '=DotWatch/DirectRTC -ffile-prefix-map=' + str(CACHE) + '=NetEqCache'
        command([cmake,'-S',ROOT / 'Native','-B',build,'-G','Ninja', '-DCMAKE_MAKE_PROGRAM=' + str(tools / 'bin' / 'ninja'), '-DCMAKE_C_COMPILER=/usr/bin/clang','-DCMAKE_CXX_COMPILER=/usr/bin/clang++', '-DCMAKE_SYSTEM_NAME=' + system,'-DCMAKE_OSX_SYSROOT=' + sdk,'-DCMAKE_OSX_ARCHITECTURES=' + arches,'-DCMAKE_OSX_DEPLOYMENT_TARGET=' + minimum,'-DCMAKE_C_FLAGS=' + mapping,'-DCMAKE_CXX_FLAGS=' + mapping,'-DDOT_WEBRTC_SOURCE=' + str(webrtc),'-DDOT_OPUS_SOURCE=' + str(opus),'-DDOT_ABSEIL_SOURCE=' + str(abseil),'-DDOT_GENERATED_INCLUDE=' + str(generated)], CACHE / (name + '-configure.log'))
        command([cmake,'--build',build,'--target','DotNetEq','-j',str(args.jobs)], CACHE / (name + '-build.log'))
        combined = build / 'libDotNetEqCombined.a'
        archives = [p for p in build.rglob('*.a') if p != combined]
        command(['/usr/bin/libtool','-static','-o',combined,*archives], CACHE / (name + '-archive.log'))
        libraries += ['-library',str(combined),'-headers',str(ROOT / 'Native' / 'include')]
    package.parent.mkdir(parents=True,exist_ok=True)
    if package.exists(): shutil.rmtree(package)
    command(['xcodebuild','-create-xcframework',*libraries,'-output',package], CACHE / 'xcframework.log')
    (package.parent / 'provenance.json').write_text(json.dumps({'webrtcCommit':WEBRTC,'opus':'1.6.1','abseil':'20260107.1','architectures':PROFILES,'sdkVersions':sdk_info,'fingerprint':fingerprint},indent=2)+'\n')
    vendor.parent.mkdir(parents=True,exist_ok=True)
    temporary = vendor.with_name('NetEqNative.xcframework.next')
    if temporary.is_symlink() or temporary.exists(): temporary.unlink()
    temporary.symlink_to(os.path.relpath(package,vendor.parent))
    if vendor.exists() and not vendor.is_symlink(): raise RuntimeError('Expected generated XCFramework symlink; preserve/relocate existing directory before preparing.')
    os.replace(temporary,vendor)
    print('NetEq XCFramework ready; immutable fingerprint: ' + fingerprint)
if __name__ == '__main__':
    try: main()
    except Exception as error: print(str(error),file=sys.stderr); sys.exit(1)
