// The database "thread", run inline.
//
// Upstream hands zone reads to a worker thread (qcommon/threads.cpp:389) and
// coordinates with two manual-reset events, both created signalled:
//
//   databaseCompletedEvent   set when the raw zone read finishes
//                            (Sys_DatabaseCompleted, end of DB_TryLoadXFile)
//   databaseCompletedEvent2  set when the post-load linking finishes
//                            (Sys_DatabaseCompleted2, end of DB_PostLoadXZone)
//
// DB_LoadXZone clears both before it queues a zone, so "an asset is missing but
// a load is in flight" is a state the engine can see. DB_FindXAssetHeader spins
// on exactly that: it looks the asset up, and while the database is not ready it
// keeps looking rather than giving up.
//
// threads.cpp is Win32-only and not ported. The stubs this replaces answered
// "ready" unconditionally, which collapsed that wait loop - DB_FindXAssetHeader
// looked once, found nothing, and fell through to DB_CreateDefaultEntry. It also
// made DB_PostLoadXZone a no-op, so nothing ever linked the entries an async load
// parks in g_copyInfo.
//
// That is what killed map loading. SV_SpawnServer queues the map zone
// asynchronously (sv_init_mp.cpp:412, sync=0) and the read only happened at the
// next sync point, which is the *following* DB_LoadXAssets. CM_LoadMap therefore
// always asked for the clipmap before the zone had been read, got a default asset,
// and the map died with "Couldn't find the bsp for this map" - while the log showed
// the clipmap registering correctly moments later.
//
// There is no worker to wait for here, so the events become plain flags and the
// notify that would wake the worker runs it instead. Doing the read on the calling
// thread has the same observable result: by the time DB_LoadXZone returns, the zone
// is in and the wait loop finds what it is looking for.

#include "qcommon/threads.h"

// db_registry.cpp:2413. The worker's pump: drains g_zoneInfo, then signals
// completion through Sys_DatabaseCompleted.
extern void DB_TryLoadXFile();

namespace
{
    // Sys_SpawnDatabaseThread creates both events signalled (threads.cpp:234-235):
    // with no load in flight the database is by definition up to date.
    bool g_readCompleted = true;
    bool g_postLoadCompleted = true;
}

void Sys_DatabaseCompleted()
{
    g_readCompleted = true;
}

void Sys_WakeDatabase()
{
    g_readCompleted = false;
}

bool Sys_IsDatabaseReady()
{
    return g_readCompleted;
}

void Sys_DatabaseCompleted2()
{
    g_postLoadCompleted = true;
}

void Sys_WakeDatabase2()
{
    g_postLoadCompleted = false;
}

bool Sys_IsDatabaseReady2()
{
    return g_postLoadCompleted;
}

// The signal that wakes the worker. DB_LoadXZone has just filled g_zoneInfo and
// wants it read; with no thread to hand it to, read it here.
void Sys_NotifyDatabase()
{
    DB_TryLoadXFile();
}

// Upstream blocks on databaseCompletedEvent. Anything queued was already read by
// Sys_NotifyDatabase, so this only has to cover a caller that syncs without having
// queued anything - the pump is a no-op when the queue is empty.
void Sys_SyncDatabase()
{
    DB_TryLoadXFile();
}

// The worker's own blocking point, and the spawn that DB_InitThread fatals without.
// Nothing runs on another thread, so there is nothing to start or wait for.
void Sys_WaitStartDatabase()
{
}

char Sys_SpawnDatabaseThread(void(*/*function*/)(unsigned int))
{
    return 1;
}

// Suspend/resume exist so the main thread can stop the worker while it touches
// shared state. With the read inline there is never a worker to suspend.
bool Sys_HaveSuspendedDatabaseThread(ThreadOwner /*owner*/)
{
    return false;
}

void Sys_ResumeDatabaseThread(ThreadOwner /*owner*/)
{
}

void Sys_SuspendDatabaseThread(ThreadOwner /*owner*/)
{
}
