#include "scr_parsetree.h"
#include <universal/assertive.h>
#include <universal/com_memory.h>
#include "scr_evaluate.h"
#include "scr_vm.h"
#include <cstring>

//struct debugger_sval_s *g_debugExprHead 83123658     scr_parsetree.obj

HunkUser *g_allocNodeUser;

void __cdecl Scr_InitAllocNode()
{
    if (g_allocNodeUser)
        MyAssertHandler(".\\script\\scr_parsetree.cpp", 66, 0, "%s", "!g_allocNodeUser");
    g_allocNodeUser = Hunk_UserCreate(0x10000, "Scr_InitAllocNode", 0, 1, 7);
}

void __cdecl Scr_ShutdownAllocNode()
{
    if (g_allocNodeUser)
    {
        Hunk_UserDestroy(g_allocNodeUser);
        g_allocNodeUser = 0;
    }
}

sval_u *__cdecl Scr_AllocNode(int size)
{
    if (!g_allocNodeUser)
        MyAssertHandler(".\\script\\scr_parsetree.cpp", 82, 0, "%s", "g_allocNodeUser");
    // Upstream asks for 4 bytes and 4-byte alignment per slot because sval_u is 4
    // bytes on x86. Here it holds a pointer and is 8, so every node array came back
    // half the size its caller writes into - node8 fills node[0..8], 72 bytes, out of
    // the 36 it was given - and each one scribbled over the node allocated after it.
    const uint32_t bytes = static_cast<uint32_t>(sizeof(sval_u)) * static_cast<uint32_t>(size);
    sval_u *const nodes = (sval_u *)Hunk_UserAlloc(g_allocNodeUser, bytes,
                                                   static_cast<int32_t>(alignof(sval_u)));
    // node0..node8 set a slot's `type` or `stringValue`, four of its eight bytes, and
    // the same slot is read back as `.node` elsewhere. Upstream got away with it
    // because four bytes was the whole slot. Zeroing means a half-written slot reads
    // as a null pointer - end of list - instead of the high half of whatever node
    // last occupied this recycled hunk memory.
    std::memset(nodes, 0, bytes);
    return nodes;
}

sval_u __cdecl node0(Enum_t type)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(1);
    result.node[0].type = type;
    return result;
}

sval_u __cdecl node1(Enum_t type, sval_u val1)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(2);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    return result;
}

sval_u __cdecl node2(Enum_t type, sval_u val1, sval_u val2)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(3);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    return result;
}

sval_u __cdecl node3(Enum_t type, sval_u val1, sval_u val2, sval_u val3)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(4);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    result.node[3].node = val3.node;
    return result;
}

sval_u __cdecl node4(Enum_t type, sval_u val1, sval_u val2, sval_u val3, sval_u val4)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(5);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    result.node[3].node = val3.node;
    result.node[4].node = val4.node;
    return result;
}

sval_u __cdecl node5(Enum_t type, sval_u val1, sval_u val2, sval_u val3, sval_u val4, sval_u val5)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(6);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    result.node[3].node = val3.node;
    result.node[4].node = val4.node;
    result.node[5].node = val5.node;
    return result;
}

sval_u __cdecl node6(Enum_t type, sval_u val1, sval_u val2, sval_u val3, sval_u val4, sval_u val5, sval_u val6)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(7);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    result.node[3].node = val3.node;
    result.node[4].node = val4.node;
    result.node[5].node = val5.node;
    result.node[6].node = val6.node;
    return result;
}

sval_u __cdecl node7(
    Enum_t type,
    sval_u val1,
    sval_u val2,
    sval_u val3,
    sval_u val4,
    sval_u val5,
    sval_u val6,
    sval_u val7)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(8);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    result.node[3].node = val3.node;
    result.node[4].node = val4.node;
    result.node[5].node = val5.node;
    result.node[6].node = val6.node;
    result.node[7].node = val7.node;
    return result;
}

sval_u __cdecl node8(
    Enum_t type,
    sval_u val1,
    sval_u val2,
    sval_u val3,
    sval_u val4,
    sval_u val5,
    sval_u val6,
    sval_u val7,
    sval_u val8)
{
    sval_u result; // eax

    result.node = Scr_AllocNode(9);
    result.node[0].type = type;
    result.node[1].node = val1.node;
    result.node[2].node = val2.node;
    result.node[3].node = val3.node;
    result.node[4].node = val4.node;
    result.node[5].node = val5.node;
    result.node[6].node = val6.node;
    result.node[7].node = val7.node;
    result.node[8].node = val8.node;
    return result;
}

// A two-slot node holding two whole values, where node1 holds a type tag and a value.
//
// The grammar builds several of these as node1(x.val.type, y): passing the payload
// through the union's 4-byte `type` member is passing the entire union on x86, so
// upstream never needed a separate function. Here `type` is half of it, and when the
// payload is a node pointer - a script's include list, a statement in an expression
// list - the parse tree ends up holding the low half of an address that the compiler
// then dereferences.
sval_u node_pair(sval_u val1, sval_u val2)
{
    sval_u result;

    result.node = Scr_AllocNode(2);
    result.node[0] = val1;
    result.node[1] = val2;
    return result;
}

// Decomp Status: Tested, Completed
sval_u linked_list_end(sval_u val1)
{
    sval_u *node;
    sval_u result;

    node = Scr_AllocNode(2);
    node[0].node = val1.node;
    // The end-of-list marker. Writing stringValue clears 4 of the slot's 8 bytes,
    // and the slot is read back as .node - append_node walks it - so the high half
    // of whatever the hunk last held there would survive as a pointer.
    node[1].node = nullptr;
    result.node = Scr_AllocNode(2);
    result.node[0].node = node;
    result.node[1].node = node;
    return result;
}

// Decomp Status: Tested, Completed
sval_u prepend_node(sval_u val1, sval_u val2)
{
    sval_u *node;

    node = Scr_AllocNode(2);
    node[0] = val1;
    node[1] = *val2.node;
    val2.node->node = node;
    return val2;
}

// Decomp Status: Tested, Completed
sval_u append_node(sval_u val1, sval_u val2)
{
    sval_u *node;

    node = Scr_AllocNode(2);
    node[0] = val2;
    node[1].node = nullptr;
    val1.node[1].node[1].node = node;
    val1.node[1].node = node;
    return val1;
}

void __cdecl Scr_ClearDebugExpr(debugger_sval_s *debugExprHead)
{
    while (debugExprHead)
    {
        // See the prefixed data in Scr_AllocDebugExpr().  The expression value is
        // a pointer to the node array, not the first four bytes of that array.
        sval_u val{};
        val.node = reinterpret_cast<sval_u *>(
            reinterpret_cast<unsigned char *>(debugExprHead) + sizeof(debugger_sval_s));
        Scr_ClearDebugExprValue(val);

        debugExprHead = debugExprHead->next;
    }
}

sval_u *__cdecl Scr_AllocDebugExpr(Enum_t type, int size, const char *name)
{
    sval_u *val; // eax
    debugger_sval_s *debugval;

    // prefix the malloc with a `debugger_sval_s`
    unsigned char *data = (unsigned char*)Z_Malloc(sizeof(debugger_sval_s) + size, name, 0);

    debugval = (debugger_sval_s *)data;
    val = (sval_u *)(data + sizeof(debugger_sval_s));

    // prepend the global list
    debugval->next = g_debugExprHead;
    g_debugExprHead = debugval;

    // A number of node fields are four-byte scalar values in an eight-byte union.
    // Clear the complete allocation so reading another union member cannot inherit
    // stale high pointer bits.
    std::memset(val, 0, static_cast<size_t>(size));

    // set val type (convenience vs. the non-debug way) and return it
    val->type = type;
    return val;
}

void __cdecl Scr_FreeDebugExpr(ScriptExpression_t *expr)
{
    debugger_sval_s *debugExprHead; // [esp+0h] [ebp-Ch]
    debugger_sval_s *nextDebugExprHead; // [esp+8h] [ebp-4h]

    if (expr->breakonExpr)
        --scrVmDebugPub.checkBreakon;

    debugExprHead = expr->exprHead;

    iassert(debugExprHead);

    while (debugExprHead)
    {
        // See Prefixed data in Scr_AllocDebugExpr()
        sval_u val{};
        val.node = reinterpret_cast<sval_u *>(
            reinterpret_cast<unsigned char *>(debugExprHead) + sizeof(debugger_sval_s));
        Scr_FreeDebugExprValue(val);

        nextDebugExprHead = debugExprHead->next;
        Z_Free(debugExprHead, 0);
        debugExprHead = nextDebugExprHead;
    }
}

sval_u __cdecl debugger_node0(Enum_t type)
{
    sval_u result{};
    result.node = Scr_AllocDebugExpr(type, sizeof(sval_u), "debugger_node0");
    return result;
}

sval_u __cdecl debugger_node1(Enum_t type, sval_u val1)
{
    sval_u result; // eax

    result.node = Scr_AllocDebugExpr(type, 2 * sizeof(sval_u), "debugger_node1");
    result.node[1] = val1;

    return result;
}

sval_u __cdecl debugger_node2(Enum_t type, sval_u val1, sval_u val2)
{
    sval_u result; // eax

    result.node = Scr_AllocDebugExpr(type, 3 * sizeof(sval_u), "debugger_node2");
    result.node[1] = val1;
    result.node[2] = val2;
    return result;
}

sval_u __cdecl debugger_node3(Enum_t type, sval_u val1, sval_u val2, sval_u val3)
{
    sval_u result; // eax

    result.node = Scr_AllocDebugExpr(type, 4 * sizeof(sval_u), "debugger_node3");
    result.node[1] = val1;
    result.node[2] = val2;
    result.node[3] = val3;
    return result;
}

sval_u __cdecl debugger_node4(Enum_t type, sval_u val1, sval_u val2, sval_u val3, sval_u val4)
{
    sval_u result; // eax

    result.node = Scr_AllocDebugExpr(type, 5 * sizeof(sval_u), "debugger_node4");
    result.node[1] = val1;
    result.node[2] = val2;
    result.node[3] = val3;
    result.node[4] = val4;
    return result;
}

sval_u __cdecl debugger_prepend_node(sval_u val1, sval_u val2)
{
    // val2 is a sentinel whose first slot points to the head [value, next]
    // pair.  debugger_node2 supplies two owned slots after its type header;
    // make those slots the new pair and update the sentinel with the full pointer.
    const sval_u oldHead = val2.node[0];
    const sval_u pair = debugger_node2(ENUM_NOP, val1, oldHead);
    val2.node[0].node = &pair.node[1];
    return val2;
}

sval_u __cdecl debugger_buffer(Enum_t type, char *buf, unsigned int size, int alignment)
{
    sval_u *result; // [esp+4h] [ebp-8h]
    unsigned __int8 *bufCopy; // [esp+8h] [ebp-4h]
    int alignmenta; // [esp+20h] [ebp+14h]

    if ((alignment & (alignment - 1)) != 0)
        MyAssertHandler((char *)".\\script\\scr_parsetree.cpp", 594, 0, "%s", "IsPowerOf2( alignment )");
    alignmenta = alignment - 1;
    result = Scr_AllocDebugExpr(
        type,
        static_cast<int>(size + static_cast<unsigned int>(alignmenta) + 2 * sizeof(sval_u)),
        "debugger_buffer");
    bufCopy = (unsigned __int8 *)(~(uintptr_t)alignmenta & ((uintptr_t)&result[2] + alignmenta));
    memcpy(bufCopy, (unsigned __int8 *)buf, size);
    result[1].debugString = reinterpret_cast<const char *>(bufCopy);

    sval_u value{};
    value.node = result;
    return value;
}

sval_u __cdecl debugger_string(Enum_t type, char *s)
{
    return debugger_buffer(type, s, strlen(s) + 1, 1);
}
