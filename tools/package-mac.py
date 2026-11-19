#!/usr/bin/env python3
"""Build the Mac app (SidraMac, Release, arm64), sign it with Developer ID and pack a DMG.
Notarizes only with an explicitly supplied notarytool Keychain profile. Modelled on Chup!'s package-release.py."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/Distribution'
DERIVED = ROOT / 'build/ReleaseDerivedData'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, **kwargs)


def sign(identity, path, *extra):
    run('codesign', '--force', '--sign', identity, '--timestamp', '--options', 'runtime', *extra, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True, help='Developer ID Application identity name or SHA-1')
    parser.add_argument('--notary-profile', help='notarytool Keychain profile; authorizes the upload to Apple')
    parser.add_argument('--build', type=int, help='CFBundleVersion; defaults to the commit count')
    args = parser.parse_args()
    build = args.build or int(subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], cwd=ROOT, text=True))
    OUT.mkdir(parents=True, exist_ok=True)
    run('xcodegen', 'generate')
    log_path = OUT / 'release-build.log'
    with log_path.open('w') as log:
        result = subprocess.run(['xcodebuild', '-project', 'Sidra.xcodeproj', '-scheme', 'SidraMac', '-configuration', 'Release',
            '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(DERIVED),
            '-skipPackagePluginValidation', '-skipMacroValidation',
            'CODE_SIGNING_ALLOWED=NO', f'CURRENT_PROJECT_VERSION={build}', 'build'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        errors = [l for l in log_path.read_text().splitlines() if ' error: ' in l or l.startswith('error:')]
        print('\n'.join(dict.fromkeys(errors)) or log_path.read_text()[-4000:])
        raise SystemExit(f'xcodebuild failed ({result.returncode}); full log in {log_path}')
    source = DERIVED / 'Build/Products/Release/Sidra.app'
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != 'nl.sadiq.sidra.mac':
        raise RuntimeError('Built the wrong app: ' + info['CFBundleIdentifier'])
    version = info['CFBundleShortVersionString'] + '-' + info['CFBundleVersion']
    dmg = OUT / f'Sidra-{version}-arm64.dmg'
    if dmg.exists():
        raise RuntimeError(f'{dmg.name} exists already. Use a new build number or move the old one.')
    with tempfile.TemporaryDirectory(prefix='sidra-package-') as folder:
        stage = pathlib.Path(folder)
        app = stage / 'Sidra.app'
        run('ditto', source, app)
        # Innermost first: Sparkle nests an app, XPC services and a bare Autoupdate tool in its framework,
        # and notarization checks every one.
        nested = [p for pattern in ('*.dylib', '*.framework', '*.xpc', '*.app') for p in app.rglob(pattern)]
        nested += list(app.glob('Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate'))
        for item in sorted(nested, key=lambda p: len(p.parts), reverse=True):
            sign(args.identity, item, '--preserve-metadata=entitlements')
        sign(args.identity, app, '--entitlements', ROOT / 'Sidra/SidraMac.entitlements')
        details = run('codesign', '-dvv', app, capture_output=True, text=True).stderr
        if 'Authority=Developer ID Application:' not in details or 'Timestamp=' not in details or 'runtime' not in details:
            raise RuntimeError('A release needs Developer ID, a secure timestamp and the hardened runtime.')
        run('codesign', '--verify', '--deep', '--strict', app)
        (stage / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', 'Sidra', '-srcfolder', stage, '-format', 'UDZO', dmg)
    run('codesign', '--sign', args.identity, '--timestamp', dmg)
    run('codesign', '--verify', '--strict', dmg)
    notarized = False
    if args.notary_profile:
        result = run('xcrun', 'notarytool', 'submit', dmg, '--keychain-profile', args.notary_profile,
                     '--wait', '--output-format', 'json', capture_output=True, text=True)
        receipt = json.loads(result.stdout)
        (OUT / f'Sidra-{version}-notary.json').write_text(json.dumps(receipt, indent=2) + '\n')
        if receipt.get('status') != 'Accepted':
            raise RuntimeError('Apple did not accept the submission. Read the notarization log before shipping.')
        run('xcrun', 'stapler', 'staple', dmg)
        run('xcrun', 'stapler', 'validate', dmg)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
        notarized = True
    report = {'version': version, 'file': dmg.name, 'notarized': notarized,
              'sha256': hashlib.file_digest(dmg.open('rb'), 'sha256').hexdigest()}
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
