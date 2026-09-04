#pragma once

#include <cstddef>
#include <cstdint>

struct cspField_t;

// One declared member of a struct, in both layouts.
//
// The config-string field tables (weaponDefFields, s_vehicleFields, ...) are
// byte offsets lifted from the x86 build, where every pointer is 4 bytes. Here
// they are 8, so an offset past the first pointer names a different field than
// it did - which is how a weapon's accuracyGraphName came back pointing into
// the middle of another field's string.
//
// The tables also index into arrays: gunModel through gunModel16 are sixteen
// offsets four apart into one member. So a member-name map is not enough; each
// run carries a stride, and translation is arithmetic inside it.
struct FieldRun
{
    uint32_t x86Offset;
    uint32_t x86Stride;
    uint32_t nativeOffset;
    uint32_t nativeStride;
    uint32_t count;
};

/**
 * Rewrite a field table's x86 byte offsets in place to native ones.
 *
 * Idempotent by way of the caller: run once per table at init. Fatals on an
 * offset that falls outside every run, which would mean the table and the
 * struct disagree about the x86 layout - the generated map is checked against
 * the recorded x86 size, so that is a table bug, not a rounding one.
 */
void Com_RemapFieldOffsets(cspField_t *fields, int fieldCount, const FieldRun *runs, int runCount,
                           const char *tableName);
