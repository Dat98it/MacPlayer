#!/usr/bin/env python3 -I
"""Lists UI strings used in the code (L("...") / LF("...")) that have no Vietnamese translation, and
translations whose %@ / %d placeholders do not match the English key. Exit code 1 if anything is wrong.
Usage: python3 -I Scripts/check_localization.py"""
import glob, re, sys

used = set()
for f in glob.glob('Sources/MacPlayer/*.swift'):
    for m in re.finditer(r'\bLF?\(\s*"((?:[^"\\]|\\.)*)"', open(f, encoding='utf-8').read()):
        used.add(m.group(1))

have = {}
for m in re.finditer(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', open('Resources/vi.lproj/Localizable.strings', encoding='utf-8').read(), re.M):
    have[m.group(1)] = m.group(2)

missing = sorted(k for k in used if k not in have)
unused = sorted(k for k in have if k not in used)
bad = [k for k in used if k in have and sorted(re.findall(r'%[@d]', k)) != sorted(re.findall(r'%[@d]', have[k]))]
for k in missing: print('MISSING :', k)
for k in bad: print('FORMAT  :', k, '->', have[k])
for k in unused: print('unused  :', k)
print(f'{len(used)} strings in code, {len(have)} translated, {len(missing)} missing, {len(bad)} with wrong placeholders, {len(unused)} unused')
sys.exit(1 if missing or bad else 0)
