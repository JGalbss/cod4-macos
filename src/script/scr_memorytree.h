#pragma once



// The allocation unit, and nothing else.
//
// Upstream stored the free tree's two node indices in the first four bytes of the
// node and let allocations use the rest, because a free node's contents are dead
// space. That makes the allocator's own bookkeeping reachable from any allocation
// that writes past its reservation - and this port has grown a lot of structures
// that are bigger here than the byte counts the callers were written against. One
// such overflow scribbles over a free node's links and the tree starts handing out
// blocks it has already handed out, far from where the mistake was made.
//
// The links live in a parallel array now, so a stray write can still corrupt
// somebody's data but cannot corrupt the allocator. MT_PoisonBlock fills free
// blocks entirely, which turns those writes into something detectable.
//
// The node is also the allocation unit, so its size sets the tree's total capacity:
// MEMORY_NODE_COUNT nodes, and the index is 16 bits so there cannot be more of them.
// The script structures stored here hold pointers and are larger at LP64, so the
// original 12 bytes ran the tree out during map load.
struct MemoryNode
{
    unsigned int payload[7];
};
static_assert(sizeof(MemoryNode) == 28,
              "MemoryNode is the allocation unit; MT_GetSize and MT_SIZE follow it");

// A free block's position in the tree, kept out of the block itself.
struct MemoryNodeLink
{
    unsigned __int16 prev;
    unsigned __int16 next;
};

#define MEMORY_NODE_BITS 16
#define MEMORY_NODE_COUNT 0x10000
#define NUM_BUCKETS 256

struct __declspec(align(128)) scrMemTreeGlob_t // sizeof=0xC0380
{                                       // XREF: .data:scrMemTreeGlob/r
    MemoryNode nodes[MEMORY_NODE_COUNT];            // XREF: MT_Init(void)+46/w
                                        // MT_Init(void)+4E/w ...
    MemoryNodeLink links[MEMORY_NODE_COUNT];
    unsigned __int8 leftBits[NUM_BUCKETS];      // XREF: MT_InitBits+89/w
                                        // MT_GetScore+88/r ...
    unsigned __int8 numBits[NUM_BUCKETS];       // XREF: MT_InitBits+59/w
                                        // MT_GetScore+6A/r ...
    unsigned __int8 logBits[NUM_BUCKETS];       // XREF: MT_InitBits+BB/w
                                        // MT_GetSize+55/r ...
    unsigned __int16 head[MEMORY_NODE_BITS + 1];// 0x242E200          // XREF: MT_DumpTree(void)+14B/r
                                        // MT_Init(void)+3A/w ...
    // padding byte
    // padding byte
    int totalAlloc;                     // XREF: MT_DumpTree(void):loc_59E783/r
                                        // MT_DumpTree(void)+1FB/r ...
    int totalAllocBuckets;              // XREF: MT_DumpTree(void):loc_59E7AE/r
};
#if UINTPTR_MAX == 0xFFFFFFFFu
static_assert(sizeof(scrMemTreeGlob_t) == 0xC0380);
#endif

[[maybe_unused]] static const char* mt_type_names[22] =
{
    "empty",
    "thread",
    "vector",
    "notetrack",
    "anim tree",
    "small anim tree",
    "external",
    "temp",
    "surface",
    "anim part",
    "model part",
    "model part map",
    "duplicate parts",
    "model list",
    "script parse",
    "script string",
    "class",
    "tag info",
    "animscripted",
    "config string",
    "debugger string",
    "generic",
};

/** True when nodeNum is the first node of a live allocation. */
bool MT_IsBlockStart(unsigned int nodeNum);

int MT_GetSubTreeSize(int nodeNum);
void MT_DumpTree(void);
void MT_FreeIndex(unsigned int nodeNum, int numBytes);

void MT_Free(unsigned char* p, int numBytes);
bool MT_Realloc(int oldNumBytes, int newNumbytes);

void MT_Init(void);
unsigned short MT_AllocIndex(int numBytes, int type);
void* MT_Alloc(int numBytes, int type);

//void TRACK_scr_memorytree(void);
//unsigned int Scr_GetStringUsage(void);

char const* MT_NodeInfoString(unsigned int nodeNum);
int MT_GetScore(int num);
void MT_AddMemoryNode(int newNode, int size);
bool MT_RemoveMemoryNode(int oldNode, unsigned int size);
void MT_RemoveHeadMemoryNode(int size);
void MT_Error(char const* funcName, int numBytes);
int MT_GetSize(int numBytes);


extern scrMemTreeGlob_t scrMemTreeGlob;