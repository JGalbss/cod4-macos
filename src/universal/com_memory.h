#pragma once

#include <script/scr_stringlist.h>
#include "q_shared.h"
#include <qcommon/mem_track.h>

#define HUNK_MAX_ALIGNEMT 4096

struct TempMemInfo // sizeof=0x28
{                                       // ...
    int permanent;
    int high;
    int highExtra;
    int hunkSize;
    int low;
    mem_track_t data;                   // ...
};

void __cdecl Hunk_AddAsset(XAssetHeader header, _DWORD *data);

void Com_TouchMemory();

unsigned __int8* __cdecl Hunk_AllocXAnimPrecache(unsigned int size);
unsigned __int8* __cdecl Hunk_AllocPhysPresetPrecache(unsigned int size);
void* __cdecl Hunk_AllocXAnimClient(int size);
unsigned __int8* __cdecl Hunk_AllocXAnimServer(unsigned int size);

//void __cdecl TRACK_com_memory();

// LWSS: Note that the Z_ prefix comes from the fact that it uses the "Zone" memory pool.
// There are a few memory pools of fixed size that allocations come from.
void* __cdecl Z_VirtualReserve(int size);
void __cdecl Z_VirtualDecommitInternal(void* ptr, int size);
void __cdecl Z_VirtualFreeInternal(void* ptr);
void* __cdecl Z_TryVirtualAllocInternal(int size);
bool __cdecl Z_TryVirtualCommitInternal(void* ptr, int size);
void __cdecl Z_VirtualCommitInternal(void* ptr, int size);
void __cdecl Z_VirtualFree(void* ptr);
void __cdecl Z_VirtualDecommit(void* ptr, int size);
char* __cdecl Z_TryVirtualAlloc(int size, const char* name, int type);
char* __cdecl Z_VirtualAlloc(int size, const char* name, int type);
void __cdecl Z_VirtualCommit(void* ptr, int size);


// LWSS: COD4 notably removes the memtag_t (Doom3BFG has these as well)
// Instead they use a per-file memory tracking system that links to qcommon\\mem_track.cpp (Anything starting with track_)
void* Z_Malloc(int size, const char* name, int type);
void  Z_Free(void* ptr, int type);

char *__cdecl Z_MallocGarbage(int size, const char *name, int type);

const char* CopyString(const char* in);
void __cdecl ReplaceString(const char** str, const char* in);
void __cdecl FreeString(const char* str);

void Com_InitHunkMemory();
void __cdecl Com_Meminfo_f();

struct HunkUser // sizeof=0x24 (32-bit upstream)
{
    HunkUser* current;
    HunkUser* next;
    int maxSize;
    // KISAKHACK-AUDIT(hunkuser-pos-end-64bit): upstream stores `pos` and
    // `end` as int because in 32-bit they hold full pointers. On aarch64
    // those pointers don't fit, and the casts in Hunk_UserCreate /
    // Hunk_UserAlloc lose the high 32 bits, returning addresses in the
    // unmapped low 4 GiB. Widen both slots to uintptr_t so the engine
    // sees real addresses; the surrounding hex-rays-style arithmetic
    // (`alignment & (alignment + pos)`, comparisons, etc.) is still
    // valid because pointer math is unsigned and the bit patterns
    // line up.
    uintptr_t end;
    uintptr_t pos;
    const char* name;
    bool fixed;
    bool tempMem;
    // padding byte
    // padding byte
    int type;
    // KISAKHACK-AUDIT(hunkuser-buf-align-64bit): Hunk_UserCreate asserts that
    // user->pos = (int)(uintptr_t)user->buf is 32-byte aligned. That holds on
    // 32-bit (sizeof=0x24, buf at 0x20) but breaks on 64-bit where the wider
    // pointers push buf to offset 0x30 — 16-byte aligned, not 32. We force
    // 32-byte alignment so the low bits of user->buf match the assertion
    // regardless of host pointer width.
    alignas(32) unsigned __int8 buf[1];
    // padding byte
    // padding byte
    // padding byte
};

// KISAKTODO: Move to proper spot?
struct fileData_s // sizeof=0xC
{
    void* data;
    fileData_s* next;
    unsigned __int8 type;
    char name[1];
    // padding byte
    // padding byte
};

void Hunk_ClearData();
void __cdecl Hunk_ClearDataFor(fileData_s** pFileData, unsigned __int8* low, unsigned __int8* high);
void __cdecl Hunk_ClearToMarkLow(int mark);
void Hunk_Clear();
int __cdecl Hunk_Used();
unsigned __int8* __cdecl Hunk_Alloc(unsigned int size, const char* name, int type);
unsigned __int8* __cdecl Hunk_AllocAlign(unsigned int size, int alignment, const char* name, int type);
// Returns a pointer. Upstream's `unsigned int` truncated the hunk address here.
void* __cdecl Hunk_AllocateTempMemoryHigh(int size, const char* name);
void Hunk_ClearTempMemoryHigh();
unsigned __int8* __cdecl Hunk_AllocLow(unsigned int size, const char* name, int type);
unsigned __int8* __cdecl Hunk_AllocLowAlign(unsigned int size, int alignment, const char* name, int type);
unsigned int* __cdecl Hunk_AllocateTempMemory(int size, const char* name);
void __cdecl Hunk_FreeTempMemory(char* buf);
void Hunk_ClearTempMemory();
void Hunk_CheckTempMemoryClear();
void Hunk_CheckTempMemoryHighClear();
int __cdecl Hunk_HideTempMemory();
void __cdecl Hunk_ShowTempMemory(int mark);
void __cdecl Hunk_InitDebugMemory();
void __cdecl Hunk_ShutdownDebugMemory();
void __cdecl Hunk_ResetDebugMem();
void* Hunk_AllocDebugMem(unsigned int size);
inline void *Hunk_AllocDebugMem(unsigned int size, const char *why) // why is rarely used and unused in this project
{
    return Hunk_AllocDebugMem(size);
}

void __cdecl Hunk_FreeDebugMem(void* ptr = NULL);
HunkUser* __cdecl Hunk_UserCreate(int maxSize, const char* name, bool fixed, bool tempMem, int type);
void* Hunk_UserAlloc(HunkUser* user, unsigned int size, int alignment);
void* Hunk_UserAllocAlignStrict(HunkUser* user, unsigned int size);
void __cdecl Hunk_UserSetPos(HunkUser* user, unsigned __int8* pos);
void __cdecl Hunk_UserReset(HunkUser* user);
void __cdecl Hunk_UserDestroy(HunkUser* user);
char* __cdecl Hunk_CopyString(HunkUser* user, const char* in);
unsigned __int8* __cdecl Hunk_AllocXModelPrecache(unsigned int size);
unsigned __int8* __cdecl Hunk_AllocXModelPrecacheColl(unsigned int size);
void* __cdecl Hunk_FindDataForFile(int type, const char* name);
void* __cdecl Hunk_FindDataForFileInternal(int type, const char* name, int hash);
bool __cdecl Hunk_DataOnHunk(unsigned __int8* data);
char* __cdecl Hunk_SetDataForFile(int type, const char* name, void* data, void* (__cdecl* alloc)(int));
void __cdecl Hunk_AddData(int type, void* data, void* (__cdecl* alloc)(int));
int Hunk_SetMarkLow();

char *__cdecl TempMalloc(unsigned int len);
void __cdecl TempMemorySetPos(char *pos);
void __cdecl TempMemoryReset(HunkUser *user);
bool __cdecl TempInfoSort(TempMemInfo *info1, TempMemInfo *info2);
char *__cdecl TempMallocAlignStrict(unsigned int len);
void __cdecl TempMemoryReset(HunkUser *user);


class LargeLocal
{
public:
    LargeLocal(int sizeParam);
    ~LargeLocal();

    unsigned __int8* GetBuf();

    int startPos;
    int size;
};

int __cdecl LargeLocalBegin(int size);
void __cdecl LargeLocalEnd(int startPos);
unsigned __int8* __cdecl LargeLocalGetBuf(int startPos);
void __cdecl LargeLocalReset();
unsigned int __cdecl LargeLocalRoundSize(int size);


extern unsigned char *s_hunkData;
extern unsigned __int8 *s_origHunkData;
extern int s_hunkTotal;