#!/usr/bin/env python3
# Emit a C translation unit embedding a PEM bundle as the libunpinca fallback.
#   gen_fallback.py <input.pem> <output.c>
import sys

data = open(sys.argv[1], "rb").read()
with open(sys.argv[2], "w") as f:
    f.write("const unsigned char unpin_ca_fallback_data[] = {")
    f.write(",".join(str(b) for b in data))
    f.write("};\n")
    f.write("const unsigned int unpin_ca_fallback_len = sizeof(unpin_ca_fallback_data);\n")
