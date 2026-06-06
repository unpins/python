#!/usr/bin/env python3
# Length-preserving scrub of a compiled-in store path in a binary.
# CPython bakes its install prefix (PREFIX/EXEC_PREFIX) into the executable as a
# NUL-terminated C string; getpath reads it to seed sys.prefix and the default
# sys.path. We replace every occurrence of the store prefix with "/unpin",
# NUL-padded to the original length so all file offsets stay byte-identical (the
# C string just terminates early at the first NUL). Safe for a static binary:
# any longer string that merely *contains* the prefix (e.g. a dead rpath) gets
# truncated at the NUL, which a static executable never consults.
import sys

binpath, store_prefix = sys.argv[1], sys.argv[2].encode()
repl = b"/unpin"
assert len(repl) <= len(store_prefix), "replacement longer than target"

with open(binpath, "rb") as f:
    data = bytearray(f.read())

n = 0
start = 0
while True:
    i = data.find(store_prefix, start)
    if i == -1:
        break
    data[i : i + len(store_prefix)] = repl + b"\x00" * (len(store_prefix) - len(repl))
    start = i + len(store_prefix)
    n += 1

assert n > 0, f"store prefix not found in {binpath}: {store_prefix!r}"
with open(binpath, "wb") as f:
    f.write(data)
print(f"scrubbed {n} occurrence(s) of the store prefix -> /unpin")
