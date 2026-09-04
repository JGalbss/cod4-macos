#!/usr/bin/env python3
"""Generate an x86 -> native field offset map for a decompiled struct.

The config-string parsers drive themselves off tables of byte offsets lifted
from the x86 binary (weaponDefFields and friends). Every pointer in those
structs is 4 bytes there and 8 here, so every offset past the first pointer
names the wrong field - and the offsets index into arrays, so a per-member
table is not enough to fix them.

This emits the layout as runs: one per declared member, carrying the x86
offset and stride the tables were built against and the native offset and
stride taken from offsetof/sizeof. Translation is then arithmetic within a
run, which handles the array cases the tables rely on.

The x86 side is computed here from a fixed size model; the native side is
left to the compiler. The generated header static_asserts the x86 total
against the size the decompiler recorded, which is what makes the size model
trustworthy rather than assumed.

  gen-struct-layout.py <header> <StructName> <expected-x86-size> <output.h>
"""
import pathlib
import re
import sys

X86_SIZES = {
    "bool": 1, "char": 1, "signed char": 1, "unsigned char": 1,
    "__int8": 1, "unsigned __int8": 1,
    "short": 2, "unsigned short": 2, "__int16": 2, "unsigned __int16": 2,
    "int": 4, "unsigned int": 4, "long": 4, "unsigned long": 4,
    "__int32": 4, "unsigned __int32": 4, "float": 4,
    "__int64": 8, "unsigned __int64": 8, "double": 8,
}
ENUM_DECL_RE = re.compile(r"\benum\s+(\w+)")
CONST_RE = re.compile(r"^\s*(?:#define\s+(\w+)\s+\(?(0x[0-9a-fA-F]+|\d+)\)?"
                      r"|(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)\s*,)\s*$", re.M)


def find_constants(root: str) -> dict:
    """Array dimensions are often named - enum constants or #defines."""
    consts = {}
    for path in pathlib.Path(root).rglob("*.h"):
        text = path.read_text(encoding="utf-8", errors="replace")
        for name1, val1, name2, val2 in CONST_RE.findall(text):
            name, val = (name1, val1) if name1 else (name2, val2)
            consts.setdefault(name, int(val, 0))
    return consts


def find_enum_names(root: str) -> set:
    """Enums are 4 bytes on both sides; anything else unknown is a hard error.

    Collected from the tree rather than listed here so a struct that gains an
    enum member does not silently fall through to a guessed size.
    """
    names = set()
    for path in pathlib.Path(root).rglob("*.h"):
        text = path.read_text(encoding="utf-8", errors="replace")
        names.update(ENUM_DECL_RE.findall(text))
    return names


def read_struct_body(header: str, name: str) -> str:
    text = open(header, encoding="utf-8", errors="replace").read()
    start = re.search(r"\bstruct\s+%s\b[^;{]*\{" % re.escape(name), text)
    if not start:
        sys.exit("struct %s not found in %s" % (name, header))
    i, depth = start.end(), 1
    while depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    body = text[start.end():i - 1]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)
    return body


def size_of(type_text: str, member: str, enums: set) -> int:
    if "*" in type_text:
        return 4
    base = " ".join(type_text.replace("const", "").split())
    base = base.replace("struct ", "").replace("enum ", "").strip()
    if base in X86_SIZES:
        return X86_SIZES[base]
    if base in enums:
        return 4
    sys.exit("unknown type %r for member %r - extend the size model" % (base, member))


def resolve_dims(dims: str, consts: dict, decl: str):
    counts = []
    for d in re.findall(r"\[\s*([^\]]+?)\s*\]", dims):
        if d.isdigit():
            counts.append(int(d))
        elif d.startswith("0x"):
            counts.append(int(d, 16))
        elif d in consts:
            counts.append(consts[d])
        else:
            sys.exit("unresolved array dimension %r in %r" % (d, decl))
    return counts


def parse_members(body: str, enums: set, consts: dict):
    members = []
    for decl in body.split(";"):
        decl = " ".join(decl.split())
        if not decl:
            continue
        # float (*name[2])[N] - an array of pointers to arrays. Only the outer
        # array is part of this struct; the pointer is the element.
        m = re.match(r"^(.*?)\(\s*\*\s*([A-Za-z_]\w*)\s*((?:\[[^\]]+\])*)\)\s*"
                     r"((?:\[[^\]]+\])*)$", decl)
        if m:
            name, dims = m.group(2), m.group(3)
            counts = resolve_dims(dims, consts, decl)
            elem = 4
            total = elem
            for c in counts:
                total *= c
            members.append((name, elem, total, len(counts) > 0))
            continue
        m = re.match(r"^(.*?)([A-Za-z_]\w*)\s*((?:\[[^\]]+\])*)$", decl)
        if not m:
            sys.exit("cannot parse member declaration %r" % decl)
        type_text, name, dims = m.group(1), m.group(2), m.group(3)
        counts = resolve_dims(dims, consts, decl)
        elem = size_of(type_text, name, enums)
        # Only the outermost dimension needs to be a run; the tables index
        # flattened arrays, and stride within a row is the element size.
        total = elem
        for c in counts:
            total *= c
        members.append((name, elem, total, len(counts) > 0))
    return members


def main() -> None:
    header, struct, expected, out = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4]
    root = pathlib.Path(header).parent.parent
    enums = find_enum_names(root)
    consts = find_constants(root)
    members = parse_members(read_struct_body(header, struct), enums, consts)
    runs, offset = [], 0
    for name, elem, total, is_array in members:
        if offset % elem:  # x86 aligns to the member's own size, max 4
            offset += elem - (offset % elem)
        runs.append((offset, elem, name, total // elem, is_array))
        offset += total
    if offset % 4:
        offset += 4 - (offset % 4)
    if offset != expected:
        sys.exit("computed x86 size 0x%x for %s, expected 0x%x - size model is wrong"
                 % (offset, struct, expected))

    lines = [
        "// Generated by mac/tools/gen-struct-layout.py - do not edit.",
        "//",
        "// x86 -> native field offsets for %s. See the generator for why." % struct,
        "#pragma once",
        "",
        '#include "universal/field_offsets.h"',
        "",
        "static constexpr FieldRun k%sLayout[] = {" % struct,
    ]
    for x86_off, elem, name, count, is_array in runs:
        subscript = "[0]" if is_array else ""
        lines.append(
            "    { %5du, %2du, (uint32_t)offsetof(%s, %s), "
            "(uint32_t)sizeof(((%s*)0)->%s%s), %4du }, // %s"
            % (x86_off, elem, struct, name, struct, name, subscript, count, name))
    lines += [
        "};",
        "",
        "static_assert(sizeof(k%sLayout) / sizeof(k%sLayout[0]) == %d, \"run count\");"
        % (struct, struct, len(runs)),
        "",
    ]
    open(out, "w", encoding="utf-8").write("\n".join(lines))
    print("%s: %d runs, x86 size 0x%x -> %s" % (struct, len(runs), offset, out))


if __name__ == "__main__":
    main()
