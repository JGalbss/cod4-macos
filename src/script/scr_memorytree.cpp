#include "scr_memorytree.h"
#include <cstdio>
#include <cstdlib>
// scrMemTreeGlob is file-static and the debugger cannot type it, so publish the
// address of one free node's payload for a watchpoint to hang off. Pick the node
// with KISAK_MT_WATCH_NODE; the poison report names the one worth watching.
extern "C" unsigned char *g_mtFreeSpaceWatch;
unsigned char *g_mtFreeSpaceWatch;
// Writing to the watched node is only suspicious while it is free - once it is
// handed out its new owner is entitled to it. A watchpoint cannot see that on its
// own, so track it here and let the condition read this.
extern "C" int g_mtWatchNodeIsFree;
int g_mtWatchNodeIsFree = 1;
static unsigned g_mtWatchNode;
#include "scr_stringlist.h"

#include <win32/win_local.h>
#include <qcommon/qcommon.h>
#include <cstdint>
#include <universal/profile.h>

scrMemTreePub_t scrMemTreePub;
int marker_scr_memorytree;

scrMemTreeGlob_t scrMemTreeGlob;

struct scrMemTreeDebugGlob_t // sizeof=0x20000
{                                       // ...
    unsigned __int8 mt_usage[MEMORY_NODE_COUNT];    // ...
    unsigned __int8 mt_usage_size[MEMORY_NODE_COUNT]; // ...
};
scrMemTreeDebugGlob_t scrMemTreeDebugGlob = {};

static void MT_InitBits(void)
{
    unsigned __int8 bits; // [esp+0h] [ebp-Ch]
    int temp; // [esp+4h] [ebp-8h]

    for (int i = 0; i < NUM_BUCKETS; ++i)
    {
        bits = 0;
        for (temp = i; temp; temp >>= 1)
        {
            if ((temp & 1) != 0)
                ++bits;
        }
        scrMemTreeGlob.numBits[i] = bits;

        for (bits = 8; (i & ((1 << bits) - 1)) != 0; --bits);

        scrMemTreeGlob.leftBits[i] = bits;
        bits = 0;
        for (temp = i; temp; temp >>= 1)
        {
            ++bits;
        }
        scrMemTreeGlob.logBits[i] = bits;
    }
}

void MT_Init()
{
	Sys_EnterCriticalSection(CRITSECT_MEMORY_TREE);

    scrMemTreePub.mt_buffer = (char*)&scrMemTreeGlob.nodes;
    MT_InitBits();

    for (int i = 0; i <= MEMORY_NODE_BITS; ++i)
        scrMemTreeGlob.head[i] = 0;

    scrMemTreeGlob.links[0].prev = 0;
    scrMemTreeGlob.links[0].next = 0;

    for (int i = 0; i < MEMORY_NODE_BITS; ++i)
        MT_AddMemoryNode(1 << i, i);

#ifdef _DEBUG
    {
        const char *watchNode = getenv("KISAK_MT_WATCH_NODE");
        g_mtWatchNode = watchNode ? (unsigned)atoi(watchNode) : 0u;
        g_mtFreeSpaceWatch = (unsigned char *)&scrMemTreeGlob.nodes[g_mtWatchNode];
    }
#endif
    scrMemTreeGlob.totalAlloc = 0;
    scrMemTreeGlob.totalAllocBuckets = 0;
    memset(scrMemTreeDebugGlob.mt_usage, 0, sizeof(scrMemTreeDebugGlob.mt_usage));
    memset(scrMemTreeDebugGlob.mt_usage_size, 0, sizeof(scrMemTreeDebugGlob.mt_usage_size));

	Sys_LeaveCriticalSection(CRITSECT_MEMORY_TREE);
}

#ifdef _DEBUG
// Walk one size's free tree looking for a node that is reachable twice or is
// marked allocated. Either means the tree's links have been overwritten - the
// blocks it hands out are the same memory its links live in, so an allocation
// that writes past its reservation corrupts the allocator itself. Reporting at
// the operation that did it beats finding out later, when MT_RemoveHeadMemoryNode
// walks into a cycle and never comes back.
static bool g_mtValidationSilenced = false;


static unsigned g_mtBadNode, g_mtBadParent;

static bool MT_WalkFree(unsigned node, unsigned parent, unsigned char *seen, int depth,
                        const char **why)
{
    if (!node)
        return true;
    g_mtBadNode = node;
    g_mtBadParent = parent;
    if (depth > MEMORY_NODE_BITS * 4)
    {
        *why = "tree deeper than it can be";
        return false;
    }
    if (seen[node])
    {
        *why = "node reachable twice";
        return false;
    }
    seen[node] = 1;
    if (scrMemTreeDebugGlob.mt_usage[node])
    {
        *why = "allocated node is in the free tree";
        return false;
    }
    return MT_WalkFree(scrMemTreeGlob.links[node].prev, node, seen, depth + 1, why)
        && MT_WalkFree(scrMemTreeGlob.links[node].next, node, seen, depth + 1, why);
}

bool MT_IsBlockStart(unsigned int nodeNum)
{
    return scrMemTreeDebugGlob.mt_usage[nodeNum] != 0;
}

// mt_usage only marks a block's first node, so walk back to find the block that
// covers this one. A free node sitting inside somebody's block is the tell: that
// block's payload is what overwrote the links.
static void MT_DescribeOwner(unsigned node, char *out, size_t outSize)
{
    for (unsigned base = node; base > 0; --base)
    {
        const int type = scrMemTreeDebugGlob.mt_usage[base];
        if (!type)
            continue;
        const unsigned span = 1u << scrMemTreeDebugGlob.mt_usage_size[base];
        const char *where = (base + span > node) ? "inside" : "just after";
        snprintf(out, outSize, "%s live block at node %u (type %d, %u nodes / %u bytes, ends at %u)",
                 where, base, type, span, span * (unsigned)MT_NODE_SIZE, base + span);
        return;
    }
    snprintf(out, outSize, "no live block below it");
}

// The last block handed out, so a tree found broken on entry can name the
// allocation whose payload most likely wrote over it.
static int g_mtLastNode, g_mtLastType, g_mtLastBytes, g_mtLastSize;

// Free memory is filled with a pattern so a stray write into it can be seen. The
// tree keeps its links in the blocks it hands out, so any write past the end of an
// allocation lands either in free space or in another allocation; this catches the
// first case, which is the one that takes the allocator down with it.
#define MT_POISON 0xAB

static void MT_PoisonBlock(unsigned node, int size)
{
    if (g_mtWatchNode >= node && g_mtWatchNode < node + (1u << size))
        g_mtWatchNodeIsFree = 1;
    memset(&scrMemTreeGlob.nodes[node], MT_POISON, (1u << size) * MT_NODE_SIZE);
}

// Report the lowest byte of free space that is no longer poison, and the block
// that sits below it - the one whose payload ran past its reservation.
static void MT_ReportPoisonDamage()
{
    static unsigned char live[MEMORY_NODE_COUNT];
    memset(live, 0, sizeof(live));
    for (unsigned n = 0; n < MEMORY_NODE_COUNT; ++n)
    {
        if (!scrMemTreeDebugGlob.mt_usage[n])
            continue;
        const unsigned span = 1u << scrMemTreeDebugGlob.mt_usage_size[n];
        for (unsigned i = n; i < n + span && i < MEMORY_NODE_COUNT; ++i)
            live[i] = 1;
    }
    for (unsigned n = 1; n < MEMORY_NODE_COUNT; ++n)
    {
        if (live[n])
            continue;
        const unsigned char *bytes = (const unsigned char *)&scrMemTreeGlob.nodes[n];
        for (size_t b = 0; b < MT_NODE_SIZE; ++b)
        {
            if (bytes[b] == MT_POISON)
                continue;
            char owner[160];
            MT_DescribeOwner(n, owner, sizeof(owner));
            std::fprintf(stderr,
                         "[mt]   free space first damaged at node %u byte %zu (0x%02x): %s\n",
                         n, b, bytes[b], owner);
            return;
        }
    }
    std::fprintf(stderr, "[mt]   free space is intact - the write went into another allocation\n");
}

static void MT_ValidateFreeList(int size, const char *where, int type, int numBytes)
{
    (void)size;
    if (g_mtValidationSilenced)
        return;
    static unsigned char seen[MEMORY_NODE_COUNT];
    memset(seen, 0, sizeof(seen));
    const char *why = "";
    for (int s = 0; s <= MEMORY_NODE_BITS; ++s)
    {
        if (MT_WalkFree(scrMemTreeGlob.head[s], 0, seen, 0, &why))
            continue;
        g_mtValidationSilenced = true;
        char badOwner[160], parentOwner[160];
        MT_DescribeOwner(g_mtBadNode, badOwner, sizeof(badOwner));
        MT_DescribeOwner(g_mtBadParent, parentOwner, sizeof(parentOwner));
        std::fprintf(stderr,
                     "[mt] free tree for size %d corrupt at %s(%d bytes, type %d): %s\n"
                     "[mt]   bad node %u: %s\n"
                     "[mt]   reached from node %u: %s\n"
                     "[mt]   last block handed out: node %d, %d bytes, type %d, reserved %d\n",
                     s, where, numBytes, type, why, g_mtBadNode, badOwner, g_mtBadParent,
                     parentOwner, g_mtLastNode, g_mtLastBytes, g_mtLastType,
                     (1 << g_mtLastSize) * (int)MT_NODE_SIZE);
        MT_ReportPoisonDamage();
        std::fflush(stderr);
        return;
    }
}
#else
#define MT_ValidateFreeList(size, where, type, numBytes) ((void)0)
#endif

void* MT_Alloc(int numBytes, int type)
{
    return &scrMemTreeGlob.nodes[MT_AllocIndex(numBytes, type)];
}

unsigned short MT_AllocIndex(int numBytes, int type)
{
    const char* v2; // eax
    const char* v3; // eax
    (void)v2; (void)v3; // hex-rays scratch; unread
    unsigned int nodeNum; // [esp+4Ch] [ebp-Ch]
    unsigned int size; // [esp+50h] [ebp-8h]
    unsigned int newSize; // [esp+54h] [ebp-4h]

    PROF_SCOPED("scriptMemory");

    size = MT_GetSize(numBytes);
    iassert(size >= 0 && size <= MEMORY_NODE_BITS);

    Sys_EnterCriticalSection(CRITSECT_MEMORY_TREE);
    // Before touching anything: if the tree is already broken, the damage came
    // from outside the allocator, and the block named below is the one to look at.
    MT_ValidateFreeList(size, "entry to MT_AllocIndex", type, numBytes);
    for (newSize = size; ; ++newSize)
    {
        if (newSize > MEMORY_NODE_BITS)
        {
            Sys_LeaveCriticalSection(CRITSECT_MEMORY_TREE);
            MT_Error("MT_AllocIndex", numBytes);
            return 0;
        }
        nodeNum = scrMemTreeGlob.head[newSize];
        if (scrMemTreeGlob.head[newSize])
            break;
    }
    MT_RemoveHeadMemoryNode(newSize);
    while (newSize != size)
    {
        --newSize;
        MT_AddMemoryNode(nodeNum + (1 << newSize), newSize);
    }
    ++scrMemTreeGlob.totalAlloc;
    scrMemTreeGlob.totalAllocBuckets += 1 << size;

    iassert(type);
    if (scrMemTreeDebugGlob.mt_usage[nodeNum])
    {
        std::fprintf(stderr,
                     "[mt] handing out live node %u: want %d bytes (type %d, size %u), "
                     "already held by type %d size %d\n",
                     nodeNum, numBytes, type, size, scrMemTreeDebugGlob.mt_usage[nodeNum],
                     scrMemTreeDebugGlob.mt_usage_size[nodeNum]);
        std::fflush(stderr);
    }
    iassert((!scrMemTreeDebugGlob.mt_usage_size[nodeNum]));

    scrMemTreeDebugGlob.mt_usage[nodeNum] = type;
    scrMemTreeDebugGlob.mt_usage_size[nodeNum] = size;
#ifdef _DEBUG
    g_mtLastNode = nodeNum; g_mtLastType = type; g_mtLastBytes = numBytes; g_mtLastSize = size;
    if (g_mtWatchNode >= nodeNum && g_mtWatchNode < nodeNum + (1u << size))
        g_mtWatchNodeIsFree = 0;
#endif
    MT_ValidateFreeList(size, "MT_AllocIndex", type, numBytes);
    Sys_LeaveCriticalSection(CRITSECT_MEMORY_TREE);
    return nodeNum;
}

bool MT_Realloc(int oldNumBytes, int newNumbytes)
{
    return MT_GetSize(oldNumBytes) >= MT_GetSize(newNumbytes);
}

void MT_RemoveHeadMemoryNode(int size)
{
    MemoryNodeLink tempNodeValue;
    int oldNode;
    MemoryNodeLink oldNodeValue;
    uint16_t *parentNode;
    int prevScore;
    int nextScore;

    iassert(size >= 0 && size <= MEMORY_NODE_BITS);

    parentNode = &scrMemTreeGlob.head[size];
    oldNodeValue = scrMemTreeGlob.links[*parentNode];

    int guard = 0;
    while (1)
    {
        // The walk rotates one node up per pass, so it cannot legitimately run longer
        // than the tree is deep. Report the state rather than spin forever.
        if (++guard > 4096)
        {
            std::fprintf(stderr, "[mt] runaway remove: size=%d head=%u cur{prev=%u,next=%u} oldNode=%d\n",
                         size, scrMemTreeGlob.head[size], oldNodeValue.prev, oldNodeValue.next, oldNode);
            unsigned n = scrMemTreeGlob.head[size];
            for (int i = 0; i < 12 && n; ++i)
            {
                std::fprintf(stderr, "[mt]   node %u -> prev %u next %u\n",
                             n, scrMemTreeGlob.links[n].prev, scrMemTreeGlob.links[n].next);
                n = scrMemTreeGlob.links[n].next;
            }
            std::fflush(stderr);
            return;
        }

        if (!oldNodeValue.prev)
        {
            oldNode = oldNodeValue.next;
            *parentNode = oldNodeValue.next;
            if (!oldNode)
            {
                break;
            }
            parentNode = &scrMemTreeGlob.links[oldNode].next;
        }
        else
        {
            if (oldNodeValue.next)
            {
                prevScore = MT_GetScore(oldNodeValue.prev);
                nextScore = MT_GetScore(oldNodeValue.next);

                iassert(prevScore != nextScore);

                if (prevScore >= nextScore)
                {
                    oldNode = oldNodeValue.prev;
                    *parentNode = oldNode;
                    parentNode = &scrMemTreeGlob.links[oldNode].prev;
                }
                else
                {
                    oldNode = oldNodeValue.next;
                    *parentNode = oldNode;
                    parentNode = &scrMemTreeGlob.links[oldNode].next;
                }
            }
            else
            {
                oldNode = oldNodeValue.prev;
                *parentNode = oldNode;
                parentNode = &scrMemTreeGlob.links[oldNode].prev;
            }
        }
        iassert(oldNode != 0);

        tempNodeValue = oldNodeValue;
        oldNodeValue = scrMemTreeGlob.links[oldNode];
        scrMemTreeGlob.links[oldNode] = tempNodeValue;
    }
}

void MT_FreeIndex(unsigned int nodeNum, int numBytes)
{
    const char* v2; // eax
    (void)v2; // hex-rays scratch; unread
    int size; // [esp+30h] [ebp-8h]
    int lowBit; // [esp+34h] [ebp-4h]

    PROF_SCOPED("scriptMemory");

    size = MT_GetSize(numBytes);

    iassert(size >= 0 && size <= MEMORY_NODE_BITS);
    iassert(nodeNum > 0 && nodeNum < MEMORY_NODE_COUNT);

    Sys_EnterCriticalSection(CRITSECT_MEMORY_TREE);
    --scrMemTreeGlob.totalAlloc;
    scrMemTreeGlob.totalAllocBuckets -= 1 << size;

    iassert(scrMemTreeDebugGlob.mt_usage[nodeNum]);

    iassert((scrMemTreeDebugGlob.mt_usage_size[nodeNum] == size));

    scrMemTreeDebugGlob.mt_usage[nodeNum] = 0;
    scrMemTreeDebugGlob.mt_usage_size[nodeNum] = 0;
    while (1)
    {
        iassert(size <= MEMORY_NODE_BITS);

        lowBit = 1 << size;

        iassert(nodeNum == (nodeNum & ~(lowBit - 1)));

        if (size == 16 || !MT_RemoveMemoryNode(lowBit ^ nodeNum, size))
            break;

        nodeNum &= ~lowBit;
        ++size;
    }
    MT_AddMemoryNode(nodeNum, size);
    MT_ValidateFreeList(size, "MT_FreeIndex", 0, numBytes);
    Sys_LeaveCriticalSection(CRITSECT_MEMORY_TREE);
}

bool __cdecl MT_RemoveMemoryNode(int oldNode, unsigned int size)
{
    MemoryNodeLink tempNodeValue;
    int node;
    MemoryNodeLink oldNodeValue;
    int nodeNum;
    uint16_t *parentNode;
    int prevScore;
    int nextScore;
    int level;

    iassert(size >= 0 && size <= MEMORY_NODE_BITS);

    nodeNum = 0;
    level = MEMORY_NODE_COUNT;
    parentNode = &scrMemTreeGlob.head[size];

    for (node = *parentNode; node; node = *parentNode)
    {
        if (oldNode == node)
        {
            oldNodeValue = scrMemTreeGlob.links[oldNode];

            while (1)
            {
                if (oldNodeValue.prev)
                {
                    if (oldNodeValue.next)
                    {
                        prevScore = MT_GetScore(oldNodeValue.prev);
                        nextScore = MT_GetScore(oldNodeValue.next);

                        iassert(prevScore != nextScore);

                        if (prevScore >= nextScore)
                        {
                            oldNode = oldNodeValue.prev;
                            *parentNode = oldNodeValue.prev;
                            parentNode = &scrMemTreeGlob.links[oldNodeValue.prev].prev;
                        }
                        else
                        {
                            oldNode = oldNodeValue.next;
                            *parentNode = oldNodeValue.next;
                            parentNode = &scrMemTreeGlob.links[oldNodeValue.next].next;
                        }
                    }
                    else
                    {
                        oldNode = oldNodeValue.prev;
                        *parentNode = oldNodeValue.prev;
                        parentNode = &scrMemTreeGlob.links[oldNodeValue.prev].prev;
                    }
                }
                else
                {
                    oldNode = oldNodeValue.next;
                    *parentNode = oldNodeValue.next;

                    if (!oldNodeValue.next)
                    {
                        return true;
                    }

                    parentNode = &scrMemTreeGlob.links[oldNodeValue.next].next;
                }

                iassert(oldNode != 0);

                tempNodeValue = oldNodeValue;
                oldNodeValue = scrMemTreeGlob.links[oldNode];
                scrMemTreeGlob.links[oldNode] = tempNodeValue;
            }
        }

        if (oldNode == nodeNum)
        {
            return false;
        }

        level >>= 1;

        if (oldNode >= nodeNum)
        {
            parentNode = &scrMemTreeGlob.links[node].next;
            nodeNum += level;
        }
        else
        {
            parentNode = &scrMemTreeGlob.links[node].prev;
            nodeNum -= level;
        }
    }

    return false;
}

void MT_Free(byte* p, int numBytes)
{
	iassert(((MemoryNode*)p - scrMemTreeGlob.nodes >= 0 && (MemoryNode*)p - scrMemTreeGlob.nodes < MEMORY_NODE_COUNT));

    MT_FreeIndex((MemoryNode *)p - scrMemTreeGlob.nodes, numBytes);
}

int MT_GetSize(int numBytes)
{
    int numBuckets; // [esp+4h] [ebp-4h]

    iassert(numBytes > 0);

    if (numBytes >= MEMORY_NODE_COUNT)
    {
        MT_Error("MT_GetSize: max allocation exceeded", numBytes);
        return 0;
    }
    else
    {
        numBuckets = (int)((numBytes + MT_NODE_SIZE - 1) / MT_NODE_SIZE) - 1;
        if (numBuckets > 255)
            return scrMemTreeGlob.logBits[numBuckets >> 8] + 8;
        else
            return scrMemTreeGlob.logBits[numBuckets];
    }
}

int MT_GetScore(int num)
{
    char bits;

    iassert(num != 0);

    union MTnum_t
    {
        int i;
        uint8_t b[4];
    };

    MTnum_t mtnum;

    mtnum.i = MEMORY_NODE_COUNT - num;
    iassert(mtnum.i != 0);

    bits = scrMemTreeGlob.leftBits[mtnum.b[0]];

    if (!mtnum.b[0])
    {
        bits += scrMemTreeGlob.leftBits[mtnum.b[1]];
    }

    return mtnum.i - (scrMemTreeGlob.numBits[mtnum.b[1]] + scrMemTreeGlob.numBits[mtnum.b[0]]) + (1 << bits);
}

int MT_GetSubTreeSize(int nodeNum)
{
    if (!nodeNum)
        return 0;

    return MT_GetSubTreeSize(scrMemTreeGlob.links[nodeNum].prev) + MT_GetSubTreeSize(scrMemTreeGlob.links[nodeNum].next) + 1;
}

void MT_AddMemoryNode(int newNode, int size)
{
    int node;
    int nodeNum;
    int newScore;
    uint16_t *parentNode;
    int level;
    int score;

    iassert(size >= 0 && size <= MEMORY_NODE_BITS);

    // The block is free from here on, so its contents are fair game. Poison first;
    // the tree writes its links into the front of it below.
    MT_PoisonBlock(newNode, size);

    parentNode = &scrMemTreeGlob.head[size];
    node = (unsigned __int16)*parentNode;

    if (node)
    {
        newScore = MT_GetScore(newNode);
        nodeNum = 0;
        level = MEMORY_NODE_COUNT;
        do
        {
            iassert(newNode != node);
            score = MT_GetScore(node);

            iassert(score != newScore);

            if (score < newScore)
            {
                while (1)
                {
                    iassert(node == *parentNode);
                    iassert(node != newNode);

                    *parentNode = newNode;
                    scrMemTreeGlob.links[newNode] = scrMemTreeGlob.links[node];
                    if (!node)
                    {
                        break;
                    }
                    level >>= 1;

                    iassert(node != nodeNum);

                    if (node >= nodeNum)
                    {
                        parentNode = &scrMemTreeGlob.links[newNode].next;
                        nodeNum += level;
                    }
                    else
                    {
                        parentNode = &scrMemTreeGlob.links[newNode].prev;
                        nodeNum -= level;
                    }
                    newNode = node;
                    node = *parentNode;
                }
                return;
            }
            level >>= 1;

            iassert(newNode != nodeNum);

            if (newNode >= nodeNum)
            {
                parentNode = &scrMemTreeGlob.links[node].next;
                nodeNum += level;
            }
            else
            {
                parentNode = &scrMemTreeGlob.links[node].prev;
                nodeNum -= level;
            }

            node = *parentNode;
        } while (node);
    }

    *parentNode = newNode;

    scrMemTreeGlob.links[newNode].prev = 0;
    scrMemTreeGlob.links[newNode].next = 0;
}

void MT_Error(const char* funcName, int numBytes)
{
    MT_DumpTree();
    Com_Printf(23, "%s: failed memory allocation of %d bytes for script usage\n", funcName, numBytes);
    Com_Error(ERR_FATAL, "MT_Error (KISAK)\n");
    //Scr_TerminalError("failed memory allocation for script usage");
}

void MT_DumpTree()
{
    int mt_type_usage[22];

    memset(mt_type_usage, 0, sizeof(mt_type_usage));

    Com_Printf(23, "********************************\n");

    int totalAlloc = 0;
    int totalAllocBuckets = 0;
    int totalBuckets = 0;
    (void)totalAlloc; (void)totalAllocBuckets; (void)totalBuckets; // accumulated but never printed in this code path

    for (int nodeNum = 0; nodeNum < MEMORY_NODE_COUNT; nodeNum++)
    {
        int type = scrMemTreeDebugGlob.mt_usage[nodeNum];
        if (type)
        {
            Com_Printf(23, "%s\n", MT_NodeInfoString(nodeNum));
            ++totalAlloc;
            totalAllocBuckets += 1 << scrMemTreeDebugGlob.mt_usage_size[nodeNum];
            mt_type_usage[type] += 1 << scrMemTreeDebugGlob.mt_usage_size[nodeNum];
        }
    }

    iassert(scrMemTreeGlob.totalAlloc == totalAlloc);
    iassert(scrMemTreeGlob.totalAllocBuckets == totalAllocBuckets);

    Com_Printf(23, "********************************\n");

    totalBuckets = scrMemTreeGlob.totalAllocBuckets;

    for (int size = 0; size <= MEMORY_NODE_BITS; ++size)
    {
        int subTreeSize = MT_GetSubTreeSize(scrMemTreeGlob.head[size]);
        totalBuckets += subTreeSize * (1 << size);
        Com_Printf(
            23,
            "%d subtree has %d * %d = %d free buckets\n",
            size,
            subTreeSize,
            1 << size,
            subTreeSize * (1 << size));
    }

    Com_Printf(23, "********************************\n");
    for (int type = 1; type < 22; ++type)
        Com_Printf(23, "'%s' allocated: %d\n", mt_type_names[type], mt_type_usage[type]);
    Com_Printf(23, "********************************\n");
    Com_Printf(
        23,
        "total memory alloc buckets: %d (%d instances)\n",
        scrMemTreeGlob.totalAllocBuckets,
        scrMemTreeGlob.totalAlloc);
    Com_Printf(23, "total memory free buckets: %d\n", 0xFFFF - scrMemTreeGlob.totalAllocBuckets);
    Com_Printf(23, "********************************\n");

    iassert(totalBuckets == (1 << MEMORY_NODE_BITS) - 1);
}

char const* MT_NodeInfoString(unsigned int nodeNum)
{
    int type = scrMemTreeDebugGlob.mt_usage[nodeNum];

    if (!scrMemTreeDebugGlob.mt_usage[nodeNum])
        return "<FREE>";

    int v3 = scrMemTreeDebugGlob.mt_usage_size[nodeNum];
    const char* v1 = SL_DebugConvertToString(nodeNum);
    return va("%s: '%s' (%d)", mt_type_names[type], v1, v3);
}