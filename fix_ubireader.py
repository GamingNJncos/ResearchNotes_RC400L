#!/usr/bin/env python3
"""Patch ubireader in WSL venv to fix extraction bugs."""
import sys

import os
site = os.path.expanduser("~/ubi_venv/lib/python3.12/site-packages/ubireader")

# Patch 1: ubi_io.py - handle 'x' gaps in LEB block map
with open(f"{site}/ubi_io.py", "r") as f:
    content = f.read()

old_io = """            if size < 0:
                raise Exception('Bad Read Offset Request')

            self._last_read_addr"""
new_io = """            if size < 0:
                raise Exception('Bad Read Offset Request')

            if leb >= len(self._blocks) or self._blocks[leb] == 'x':
                self.seek(self.tell() + size)
                return bytes([0xff]) * size

            self._last_read_addr"""
if old_io in content:
    content = content.replace(old_io, new_io)
    with open(f"{site}/ubi_io.py", "w") as f:
        f.write(content)
    print("ubi_io.py: patched LEB gap handling")
else:
    print("ubi_io.py: already patched or pattern not found")

# Patch 2: walk.py - negative read_size + truncated node handling
with open(f"{site}/ubifs/walk.py", "r") as f:
    content = f.read()

patched = False

# 2a: Guard negative read_size
old_w1 = "    node_buf = ubifs.file.read(read_size)\n    file_offset = ubifs.file.last_read_addr()"
new_w1 = """    if read_size <= 0:
        error(index, 'Error', 'LEB: %s, Invalid read size (chdr.len=%s), skipping.' % (lnum, chdr.len))
        return
    node_buf = ubifs.file.read(read_size)
    file_offset = ubifs.file.last_read_addr()"""
if old_w1 in content:
    content = content.replace(old_w1, new_w1, 1)
    patched = True
    print("walk.py: patched negative read_size guard")

# 2b: Common hdr too small - Error+return instead of conditional Fatal
old_w2 = """        if settings.warn_only_block_read_errors:
            error(index, 'Error', 'LEB: %s, Common Hdr Size smaller than expected.' % (lnum))
            return

        else:
            error(index, 'Fatal', 'LEB: %s, Common Hdr Size smaller than expected.' % (lnum))"""
new_w2 = """        error(index, 'Error', 'LEB: %s, Common Hdr Size smaller than expected, skipping.' % (lnum))
        return"""
if old_w2 in content:
    content = content.replace(old_w2, new_w2, 1)
    patched = True
    print("walk.py: patched common hdr size error")

# 2c: Node size smaller than expected - Error+return instead of Fatal
old_w3 = """    if len(node_buf) < read_size:
        if settings.warn_only_block_read_errors:
            error(index, 'Error', 'LEB: %s at %s, Node size smaller than expected.' % (lnum, file_offset))
            return

        else:
            error(index, 'Fatal', 'LEB: %s at %s, Node size smaller than expected.' % (lnum, file_offset))"""
new_w3 = """    if len(node_buf) < read_size:
        error(index, 'Error', 'LEB: %s at %s, Node size smaller than expected, skipping.' % (lnum, file_offset))
        return"""
if old_w3 in content:
    content = content.replace(old_w3, new_w3, 1)
    patched = True
    print("walk.py: patched truncated node error")

if patched:
    with open(f"{site}/ubifs/walk.py", "w") as f:
        f.write(content)
else:
    print("walk.py: already patched or patterns not found")

# Patch 3: decrypt.py - surrogateescape for non-UTF8 filenames
with open(f"{site}/ubifs/decrypt.py", "r") as f:
    content = f.read()
old_d = "dent.raw_name.decode()"
new_d = "dent.raw_name.decode('utf-8', errors='surrogateescape')"
if old_d in content:
    content = content.replace(old_d, new_d)
    with open(f"{site}/ubifs/decrypt.py", "w") as f:
        f.write(content)
    print("decrypt.py: patched UTF-8 decode")
else:
    print("decrypt.py: already patched")

print("\nAll patches applied successfully.")
