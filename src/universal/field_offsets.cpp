#include "field_offsets.h"
#include "q_shared.h"
#include "qcommon/qcommon.h"

void Com_RemapFieldOffsets(cspField_t *fields, int fieldCount, const FieldRun *runs, int runCount,
                           const char *tableName)
{
    for (int i = 0; i < fieldCount; ++i)
    {
        const uint32_t x86Offset = static_cast<uint32_t>(fields[i].iOffset);
        const FieldRun *match = nullptr;
        for (int r = 0; r < runCount && !match; ++r)
        {
            const FieldRun &run = runs[r];
            if (x86Offset >= run.x86Offset && x86Offset < run.x86Offset + run.x86Stride * run.count)
                match = &run;
        }
        if (!match)
        {
            Com_Error(ERR_FATAL, "%s: field \"%s\" has x86 offset %u, which is not in %s's layout",
                      tableName, fields[i].szName, x86Offset, tableName);
            return;
        }
        const uint32_t index = (x86Offset - match->x86Offset) / match->x86Stride;
        fields[i].iOffset = static_cast<int>(match->nativeOffset + index * match->nativeStride);
    }
}
