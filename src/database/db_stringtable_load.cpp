#include "database.h"

void __cdecl Load_ScriptStringCustom(uint16_t *var)
{
    // KISAKHACK: stringList.strings[] holds 32-bit string ids stored in
    // 64-bit pointer slots on a 64-bit host; cast through uintptr_t.
    *var = (uint16_t)(uintptr_t)varXAssetList->stringList.strings[*var];
}

void __cdecl Mark_ScriptStringCustom(uint16_t *var)
{
    if (*var)
        SL_AddUser(*var, 4u);
}

