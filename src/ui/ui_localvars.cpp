#include "ui_shared.h"

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <universal/com_memory.h>

void __cdecl UILocalVar_Init(UILocalVarContext *context)
{
    if (!context)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 23, 0, "%s", "context");

    // Start empty. The decompiled body only had the assert, which left every slot
    // holding whatever was in that memory - and Shutdown walks all 256 freeing any
    // entry whose name looks non-null, so it handed garbage to FreeString. Shutdown
    // memsets the context on the way out, so zeroing on the way in is the intent.
    memset(context, 0, sizeof(*context));
}

void __cdecl UILocalVar_Shutdown(UILocalVarContext *context)
{
    unsigned int hash; // [esp+4h] [ebp-4h]

    if (!context)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 31, 0, "%s", "context");
    for (hash = 0; hash < 0x100; ++hash)
    {
        if (context->table[hash].name)
        {
            // A string var can be left holding nothing - CopyString of an empty menu
            // value - and FreeString walks the string table with strlen, so a null
            // here faults rather than being a no-op.
            // Only entries with a real type are live. UI_Shutdown runs from
            // CL_ShutdownHunkUsers, which has already released the hunk these strings
            // came from, so a slot can hold a stale name pointer with a type that is
            // not one of the three - and FreeString walks the string table with
            // strlen, so following one faults.
            const UILocalVarType type = context->table[hash].type;
            if (type != UILOCALVAR_INT && type != UILOCALVAR_FLOAT && type != UILOCALVAR_STRING)
                continue;

            // WORKAROUND, root cause not yet found. By the time UI_Shutdown runs during
            // SV_SpawnServer, a slot can hold a valid type with a name pointer of 0x30
            // or similar - a small integer, not a freed-but-mapped address - so
            // something writes into this table rather than the strings merely going
            // stale. FreeString reaches it through strlen and faults.
            //
            // Refusing to free an address that cannot be a string leaks that entry but
            // lets the map load proceed. Remove this once the writer is identified.
            const auto plausible = [](const char *s) { return reinterpret_cast<uintptr_t>(s) > 0x10000u; };

            if (type == UILOCALVAR_STRING && plausible(context->table[hash].u.string))
                FreeString(context->table[hash].u.string);
            if (plausible(context->table[hash].name))
                FreeString(context->table[hash].name);
        }
    }
    memset((unsigned __int8 *)context, 0, sizeof(UILocalVarContext));
}

UILocalVarContext *__cdecl UILocalVar_Find(UILocalVarContext *context, const char *name)
{
    unsigned int hash; // [esp+0h] [ebp-4h] BYREF

    if (UILocalVar_FindLocation(context, name, &hash))
        return (UILocalVarContext *)&context->table[hash];
    else
        return 0;
}

char __cdecl UILocalVar_FindLocation(UILocalVarContext *context, const char *name, unsigned int *hashForName)
{
    unsigned int hash; // [esp+1Ch] [ebp-8h]
    unsigned int initialHash; // [esp+20h] [ebp-4h]

    initialHash = UILocalVar_HashName(name);
    hash = initialHash;
    do
    {
        if (!context->table[hash].name)
            break;
        if (!strcmp(context->table[hash].name, name))
        {
            *hashForName = hash;
            return 1;
        }
        hash = (unsigned __int8)(hash + 1);
    } while (hash != initialHash);
    *hashForName = hash;
    return 0;
}

unsigned int __cdecl UILocalVar_HashName(const char *name)
{
    __int16 hash; // [esp+0h] [ebp-8h]
    unsigned int i; // [esp+4h] [ebp-4h]

    hash = 0;
    for (i = 0; name[i]; ++i)
        hash += (i + 119) * name[i];
    return (unsigned __int8)(hash + HIBYTE(hash));
}

UILocalVarContext *__cdecl UILocalVar_FindOrCreate(UILocalVarContext *context, char *name)
{
    UILocalVar *var; // [esp+0h] [ebp-8h]
    unsigned int hash; // [esp+4h] [ebp-4h] BYREF

    if (UILocalVar_FindLocation(context, name, &hash))
        return (UILocalVarContext *)&context->table[hash];
    var = &context->table[hash];
    var->name = CopyString(name);
    var->type = UILOCALVAR_INT;
    var->u.integer = 0;
    return (UILocalVarContext *)var;
}

bool __cdecl UILocalVar_GetBool(const UILocalVar *var)
{
    if (!var)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 114, 0, "%s", "var");
    if (var->type == UILOCALVAR_INT)
        return var->u.integer != 0;
    if (var->type == UILOCALVAR_FLOAT)
        return var->u.value != 0.0;
    if (var->type != UILOCALVAR_STRING)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 125, 0, "var->type == UILOCALVAR_STRING\n\t%i, %i", var->type, 2);
    return atoi(var->u.string) != 0;
}

UILocalVar_u __cdecl UILocalVar_GetInt(const UILocalVar *var)
{
    if (!var)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 133, 0, "%s", "var");
    if (var->type)
    {
        if (var->type == UILOCALVAR_FLOAT)
        {
            return (UILocalVar_u)(int)var->u.value;
        }
        else
        {
            if (var->type != UILOCALVAR_STRING)
                MyAssertHandler(".\\ui\\ui_localvars.cpp", 144, 0, "var->type == UILOCALVAR_STRING\n\t%i, %i", var->type, 2);
            return (UILocalVar_u)atoi(var->u.string);
        }
    }
    else
    {
        return var->u;
    }
}

double __cdecl UILocalVar_GetFloat(const UILocalVar *var)
{
    if (!var)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 152, 0, "%s", "var");
    if (var->type == UILOCALVAR_INT)
        return (double)var->u.integer;
    if (var->type == UILOCALVAR_FLOAT)
        return var->u.value;
    if (var->type != UILOCALVAR_STRING)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 163, 0, "var->type == UILOCALVAR_STRING\n\t%i, %i", var->type, 2);
    return (float)atof(var->u.string);
}

char *__cdecl UILocalVar_GetString(const UILocalVar *var, char *stringBuf, unsigned int size)
{
    if (!var)
        MyAssertHandler(".\\ui\\ui_localvars.cpp", 171, 0, "%s", "var");
    if (var->type)
    {
        if (var->type == UILOCALVAR_FLOAT)
        {
            Com_sprintf(stringBuf, size, "%g", var->u.value);
            return stringBuf;
        }
        else
        {
            if (var->type != UILOCALVAR_STRING)
                MyAssertHandler(".\\ui\\ui_localvars.cpp", 184, 0, "var->type == UILOCALVAR_STRING\n\t%i, %i", var->type, 2);
            return const_cast<char *>(var->u.string);
        }
    }
    else
    {
        Com_sprintf(stringBuf, size, "%i", var->u.integer);
        return stringBuf;
    }
}

void __cdecl UILocalVar_SetBool(UILocalVar *var, bool b)
{
    if (var->type == UILOCALVAR_STRING)
        FreeString(var->u.string);
    var->type = UILOCALVAR_INT;
    var->u.integer = b;
}

void __cdecl UILocalVar_SetInt(UILocalVar *var, int i)
{
    if (var->type == UILOCALVAR_STRING)
        FreeString(var->u.string);
    var->type = UILOCALVAR_INT;
    var->u.integer = i;
}

void __cdecl UILocalVar_SetFloat(UILocalVar *var, float f)
{
    if (var->type == UILOCALVAR_STRING)
        FreeString(var->u.string);
    var->type = UILOCALVAR_FLOAT;
    var->u.value = f;
}

void __cdecl UILocalVar_SetString(UILocalVar *var, char *s)
{
    if (var->type == UILOCALVAR_STRING)
        FreeString(var->u.string);
    var->type = UILOCALVAR_STRING;
    var->u.string = CopyString(s);
}

