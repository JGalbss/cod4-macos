#!/usr/bin/env bash
# A dvar value is a union: `string` and `integer` share offset 0. On x86 that let the
# decompiler read a string dvar through `current.integer`, and it worked. At LP64
# `integer` is 32 bits and truncates the pointer, so every such read is a crash that
# only fires when that code path is finally reached.
#
# Run from the repo root. Non-zero exit means someone reintroduced the pattern.
set -uo pipefail
cd "$(dirname "$0")/../.."

hits=$(LC_ALL=C grep -rnE '\((const )?char ?\*\)(\(uintptr_t\))?[A-Za-z_][A-Za-z0-9_>.-]*->current\.integer|\*\(_BYTE \*\)\(uintptr_t\)[A-Za-z_][A-Za-z0-9_>.-]*->current\.integer' src/ 2>/dev/null || true)

if [ -n "$hits" ]; then
    echo "dvar union misuse - read .string, not .integer:"
    echo "$hits"
    exit 1
fi
# Console message windows were reached as negative float offsets from con.color,
# with strides baked for the x86 layout of Console. Those move at LP64.
conhits=$(LC_ALL=C grep -rn 'con\.color\[4630' src/ 2>/dev/null || true)
if [ -n "$conhits" ]; then
    echo "console window reached by x86 float offset - name the member instead:"
    echo "$conhits"
    exit 1
fi

# Same class in the UI's local variable table: u.integer and u.string share offset 0.
uvhits=$(LC_ALL=C grep -rnE '\(char ?\*\)\(uintptr_t\)[A-Za-z_][A-Za-z0-9_>.-]*->u\.integer|->u\.integer = \(int\)\(uintptr_t\)' src/ 2>/dev/null || true)
if [ -n "$uvhits" ]; then
    echo "union misuse - a pointer held in .integer truncates at LP64:"
    echo "$uvhits"
    exit 1
fi

echo "ok: no pointer stored or read through a union's integer member"
