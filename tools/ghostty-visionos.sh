#!/bin/zsh
# Adds visionOS slices to Packages/SidraTerminal/Vendor/ghostty-vt.xcframework (2026-11-24).
# Zig's stdlib cannot target visionOS yet, so the iOS arm64 objects (pure VT code, no UIKit) are relabelled:
# each object's LC_BUILD_VERSION platform becomes visionOS (11) or its simulator (12). Rerun after updating the iOS slices.
set -e
V=${0:a:h}/../Packages/SidraTerminal/Vendor/ghostty-vt.xcframework
T=$(mktemp -d)
retag() {   # <src.a> <out dir> <platform id>
  mkdir -p $2/o; (cd $2/o && ar -x $1 2>/dev/null; chmod 644 *.o; rm -f "__.SYMDEF SORTED"
  python3 -I - $3 *.o <<'PY'
import struct, sys
plat = int(sys.argv[1])
for path in sys.argv[2:]:
    b = bytearray(open(path, 'rb').read()); assert struct.unpack_from('<I', b, 0)[0] == 0xfeedfacf, path
    off = 32
    for _ in range(struct.unpack_from('<I', b, 16)[0]):
        cmd, size = struct.unpack_from('<II', b, off)
        if cmd == 0x32: struct.pack_into('<II', b, off + 8, plat, 26 << 16)   # LC_BUILD_VERSION: platform, minos 26.0
        off += size
    open(path, 'wb').write(b)
PY
  libtool -static -o ../libghostty-vt.a *.o 2>/dev/null)
}
retag $V/ios-arm64/libghostty-vt-fat.a $T/xros 11
retag $V/ios-arm64-simulator/libghostty-vt-fat.a $T/xrsim 12
xcodebuild -create-xcframework \
  -library $V/macos-arm64_x86_64/libghostty-vt.a -headers $V/macos-arm64_x86_64/Headers \
  -library $V/ios-arm64/libghostty-vt-fat.a -headers $V/ios-arm64/Headers \
  -library $V/ios-arm64-simulator/libghostty-vt-fat.a -headers $V/ios-arm64-simulator/Headers \
  -library $T/xros/libghostty-vt.a -headers $V/ios-arm64/Headers \
  -library $T/xrsim/libghostty-vt.a -headers $V/ios-arm64/Headers -output $T/out.xcframework
rm -rf $V && mv $T/out.xcframework $V && rm -rf $T
