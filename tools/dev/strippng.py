# Remove eXIf chunks from PNGs so viewers do not re-rotate pixel-rotated screenshots.
import struct, sys, zlib
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', path
    out = bytearray(d[:8]); i = 8; removed = 0
    while i < len(d):
        n = struct.unpack('>I', d[i:i+4])[0]; t = d[i+4:i+8]
        chunk = d[i:i+12+n]
        if t == b'eXIf': removed += 1
        else: out += chunk
        i += 12 + n
    open(path, 'wb').write(out)
    print(path.split('/')[-1], 'removed', removed)
