#pragma once

#include <qcommon/net_chan_mp.h>

struct msg_t;

// CoD4x protocol 21 carries large control messages (notably gamestates and
// downloads) over a small selective-ack UDP stream alongside IW3's netchan.
// These entry points own the one stream used by the local multiplayer client.
void Cod4x_ReliableSetup(netsrc_t sock, int qport, netadr_t remoteAddress);
void Cod4x_ReliableDisconnect();
bool Cod4x_ReliableIsConnected();
void Cod4x_ReliableReceivePacket(msg_t *msg);
void Cod4x_ReliableFrame(int now);
bool Cod4x_ReliableSendMessage(msg_t *msg);
