#!/usr/bin/env python3
"""Compare OpenAssetTools' IW3 asset structs against KisakCOD's.

Both trees render the same CoD4 structs; OAT's loader already produces LP64 data.
If the field lists agree, a generated field-by-field converter replaces the
hand-written transcoders that stalled this port.
"""
import re, sys, pathlib

# A field statement is any declaration ending in ';'. The two trees spell types
# differently - KisakCOD emits the decompiler's "unsigned __int8", OAT writes
# "const char* name" with the star glued to the type - so normalise the stars away
# and take the identifier that sits just before the array suffix and semicolon.
FIELD = re.compile(r"^\s*(?:[\w:]+\s+)+(\w+)\s*(?:\[[^\]]*\])*\s*;\s*$")

def field_name(line):
    line = re.sub(r"//.*$", "", line).replace("*", " ")
    m = FIELD.match(line)
    if not m: return None
    return m.group(1) if m.group(1) not in ("const","unsigned","signed","struct","union") else None

SKIP = re.compile(r"^\s*(//|/\*|\*|#|union|struct\s*\{|\}|$)")

def structs(text):
    """Map struct name -> ordered field names, by brace matching."""
    out, i = {}, 0
    for m in re.finditer(r"\bstruct\s+(\w+)\s*(?://[^\n]*)?\n?\s*\{", text):
        name, depth, j = m.group(1), 1, m.end()
        while j < len(text) and depth:
            if text[j] == "{": depth += 1
            elif text[j] == "}": depth -= 1
            j += 1
        body = text[m.end():j-1]
        fields = []
        for line in body.splitlines():
            if SKIP.match(line): continue
            f = field_name(line)
            if f: fields.append(f)
        if fields: out.setdefault(name, fields)
    return out

oat = pathlib.Path(sys.argv[1]).read_text(errors="replace")
oat_s = structs(oat)

kis = {}
for p in pathlib.Path(sys.argv[2]).rglob("*.h"):
    try: kis.update(structs(p.read_text(errors="replace")))
    except Exception: pass

# The asset types the engine's pools actually hold.
ASSETS = ["PhysPreset","XAnimParts","XModel","Material","MaterialTechniqueSet","GfxImage",
          "snd_alias_list_t","SndCurve","LoadedSound","clipMap_t","ComWorld","GameWorldSp",
          "GameWorldMp","MapEnts","GfxWorld","GfxLightDef","Font_s","MenuList","menuDef_t",
          "LocalizeEntry","WeaponDef","FxEffectDef","FxImpactTable","RawFile","StringTable"]

same = diff = missing = 0
print(f"{'asset type':<26} {'OAT':>5} {'Kisak':>6}  verdict")
print("-"*62)
for a in ASSETS:
    o, k = oat_s.get(a), kis.get(a)
    if o is None or k is None:
        print(f"{a:<26} {len(o) if o else '-':>5} {len(k) if k else '-':>6}  NOT FOUND"); missing += 1; continue
    if o == k:
        print(f"{a:<26} {len(o):>5} {len(k):>6}  IDENTICAL"); same += 1
    else:
        extra = [f for f in o if f not in k][:3]
        gone  = [f for f in k if f not in o][:3]
        note = f"oat-only={extra} kisak-only={gone}" if (extra or gone) else "same names, different order"
        print(f"{a:<26} {len(o):>5} {len(k):>6}  DIFFERS  {note}"); diff += 1
print("-"*62)
print(f"identical={same}  differ={diff}  not-found={missing}   (of {len(ASSETS)})")
print(f"parsed: OAT {len(oat_s)} structs, KisakCOD {len(kis)} structs")
