#ifndef KISAK_MP
#error This file is multiplayer-only
#endif

#include "cod4x_reliable.h"

#include "cod4x_client.h"

#include <client_mp/client_mp.h>
#include <qcommon/msg_mp.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

namespace
{
constexpr int kReliableMarker = static_cast<int>(0xfffffff0u);
constexpr int kFragmentSize = 1200;
constexpr int kFragmentCount = 32;
constexpr int kReceiveWindow = 20;
constexpr int kSendWindow = 4;
constexpr int kMaxLogicalMessage = 1024 * 1024;

struct Fragment
{
    std::array<unsigned char, kFragmentSize> data{};
    int length = 0;
    int acknowledge = -1;
};

struct ReliableChannel
{
    bool connected = false;
    netsrc_t socket = NS_CLIENT1;
    int qport = 0;
    netadr_t remoteAddress{};
    int receiveSequence = 0;
    int transmitSequence = 0;
    int transmitAcknowledge = 0;
    int transmitFrame = 0;
    int nextAckTime = 0;
    int time = 0;
    int selectiveAckOffset = 1;
    std::array<Fragment, kFragmentCount> receiveFragments{};
    std::array<Fragment, kFragmentCount> transmitFragments{};
    std::vector<unsigned char> stream;
};

ReliableChannel channel;
int traceSendCount;
int traceReceiveCount;

int ContiguousReceiveSequence()
{
    int offset = 0;
    for (; offset < kReceiveWindow; ++offset)
    {
        const int sequence = channel.receiveSequence + offset;
        if (channel.receiveFragments[sequence % kFragmentCount].acknowledge != sequence)
            break;
    }
    return channel.receiveSequence + offset;
}

void WriteSelectiveAcks(msg_t *msg)
{
    const int countOffset = msg->cursize;
    MSG_WriteByte(msg, 0);

    int rangeCount = 0;
    bool inRange = false;
    int rangeLength = 0;
    int offset = channel.selectiveAckOffset;
    for (; offset < kReceiveWindow; ++offset)
    {
        const int sequence = channel.receiveSequence + offset;
        const bool received = channel.receiveFragments[sequence % kFragmentCount].acknowledge == sequence;
        if (received && !inRange)
        {
            MSG_WriteShort(msg, static_cast<short>(offset));
            ++rangeCount;
            rangeLength = 0;
        }

        if (received)
        {
            inRange = true;
            ++rangeLength;
        }
        else if (inRange)
        {
            MSG_WriteShort(msg, static_cast<short>(rangeLength));
            inRange = false;
            if (rangeCount >= 3)
                break;
        }
    }

    if (inRange)
        MSG_WriteShort(msg, static_cast<short>(rangeLength));
    channel.selectiveAckOffset = offset < kReceiveWindow ? offset : 1;
    msg->data[countOffset] = static_cast<unsigned char>(rangeCount);
}

void SendAcknowledge()
{
    unsigned char packet[1400];
    msg_t msg{};
    MSG_Init(&msg, packet, sizeof(packet));
    MSG_WriteLong(&msg, kReliableMarker);
    MSG_WriteShort(&msg, static_cast<short>(channel.qport));
    MSG_WriteLong(&msg, -1); // ACK-only frame
    MSG_WriteLong(&msg, channel.receiveSequence);
    MSG_WriteByte(&msg, 0);
    WriteSelectiveAcks(&msg);
    MSG_WriteShort(&msg, kSendWindow);
    MSG_WriteShort(&msg, 0);
    NET_SendPacket(channel.socket, msg.cursize, msg.data, channel.remoteAddress);
    if (traceSendCount++ < 4)
        Com_Printf(14, "CoD4x: reliable ACK tx qport=%u receiveSequence=%d bytes=%d\n",
            static_cast<unsigned int>(static_cast<unsigned short>(channel.qport)),
            channel.receiveSequence, msg.cursize);
    channel.nextAckTime = channel.time + 350;
}

void TransmitNextFragment()
{
    if (channel.transmitFrame < channel.transmitAcknowledge)
        channel.transmitFrame = channel.transmitAcknowledge;

    if (channel.transmitFrame >= channel.transmitSequence)
    {
        SendAcknowledge();
        return;
    }

    const int sequence = channel.transmitFrame;
    Fragment &fragment = channel.transmitFragments[sequence % kFragmentCount];
    unsigned char packet[1400];
    msg_t msg{};
    MSG_Init(&msg, packet, sizeof(packet));
    MSG_WriteLong(&msg, kReliableMarker);
    MSG_WriteShort(&msg, static_cast<short>(channel.qport));
    MSG_WriteLong(&msg, sequence);
    MSG_WriteLong(&msg, channel.receiveSequence);
    MSG_WriteByte(&msg, 0);
    WriteSelectiveAcks(&msg);
    MSG_WriteShort(&msg, kSendWindow);
    MSG_WriteShort(&msg, static_cast<short>(fragment.length));
    MSG_WriteData(&msg, fragment.data.data(), fragment.length);
    NET_SendPacket(channel.socket, msg.cursize, msg.data, channel.remoteAddress);
    channel.nextAckTime = channel.time + 350;
    if (traceSendCount++ < 8)
        Com_Printf(14, "CoD4x: reliable tx sequence=%d acknowledge=%d bytes=%d\n",
            sequence, channel.receiveSequence, msg.cursize);

    ++channel.transmitFrame;
    if (channel.transmitFrame >= channel.transmitSequence
        || channel.transmitFrame >= channel.transmitAcknowledge + kSendWindow)
    {
        channel.transmitFrame = channel.transmitAcknowledge;
    }
}

void AppendContiguousFragments()
{
    const int highSequence = ContiguousReceiveSequence();
    while (channel.receiveSequence < highSequence)
    {
        Fragment &fragment = channel.receiveFragments[channel.receiveSequence % kFragmentCount];
        channel.stream.insert(channel.stream.end(), fragment.data.begin(), fragment.data.begin() + fragment.length);
        fragment.length = 0;
        fragment.acknowledge = -1;
        ++channel.receiveSequence;
    }
    if (highSequence - channel.receiveSequence > 1)
        channel.selectiveAckOffset = 1;
}

uint32_t ReadLittleU32(const unsigned char *data)
{
    return static_cast<uint32_t>(data[0])
        | (static_cast<uint32_t>(data[1]) << 8)
        | (static_cast<uint32_t>(data[2]) << 16)
        | (static_cast<uint32_t>(data[3]) << 24);
}

void ProcessLogicalMessages()
{
    while (channel.stream.size() >= 4)
    {
        const uint32_t messageSize = ReadLittleU32(channel.stream.data());
        if (messageSize > kMaxLogicalMessage)
        {
            Com_Error(ERR_DROP, "CoD4x: reliable message is too large (%u bytes)", messageSize);
            return;
        }
        if (channel.stream.size() < static_cast<size_t>(messageSize) + 4)
            return;

        msg_t message{};
        MSG_InitReadOnly(&message, channel.stream.data(), static_cast<int>(messageSize + 4));
        MSG_BeginReading(&message);
        MSG_ReadLong(&message); // logical-message length
        Cod4x_ExecuteReliableMessage(&message);

        channel.stream.erase(
            channel.stream.begin(),
            channel.stream.begin() + static_cast<ptrdiff_t>(messageSize + 4));
    }
}
}

void Cod4x_ReliableSetup(netsrc_t sock, int qport, netadr_t remoteAddress)
{
    channel = {};
    channel.connected = true;
    channel.socket = sock;
    channel.qport = qport;
    channel.remoteAddress = remoteAddress;
    channel.selectiveAckOffset = 1;
    channel.stream.reserve(64 * 1024);
    traceSendCount = 0;
    traceReceiveCount = 0;
    Com_Printf(14, "CoD4x: reliable control channel established (qport %u)\n",
        static_cast<unsigned int>(static_cast<unsigned short>(qport)));
}

void Cod4x_ReliableDisconnect()
{
    channel = {};
}

bool Cod4x_ReliableIsConnected()
{
    return channel.connected;
}

void Cod4x_ReliableReceivePacket(msg_t *msg)
{
    if (!channel.connected)
        return;

    const int sequence = MSG_ReadLong(msg);
    const int acknowledge = MSG_ReadLong(msg);
    const int flags = MSG_ReadByte(msg);
    if (traceReceiveCount++ < 12)
        Com_Printf(14, "CoD4x: reliable rx sequence=%d acknowledge=%d bytes=%d\n",
            sequence, acknowledge, msg->cursize);
    if (msg->overflowed)
        return;
    if (flags & 1)
        channel.nextAckTime = 0;

    if (sequence >= channel.receiveSequence + kReceiveWindow)
        return;
    if (acknowledge < channel.transmitAcknowledge
        || acknowledge > channel.transmitSequence
        || acknowledge > channel.transmitAcknowledge + kSendWindow)
    {
        Com_PrintWarning(14, "CoD4x: ignored invalid reliable acknowledgement %d\n", acknowledge);
        return;
    }

    const int selectiveAckCount = MSG_ReadByte(msg);
    if (selectiveAckCount < 0 || selectiveAckCount > 3)
        return;
    for (int i = 0; i < selectiveAckCount; ++i)
    {
        const int start = acknowledge + MSG_ReadShort(msg);
        const int length = MSG_ReadShort(msg);
        if (start < acknowledge || start + length > acknowledge + kSendWindow)
            return;
        for (int item = 0; item < length; ++item)
            channel.transmitFragments[(start + item) % kFragmentCount].acknowledge = start + item;
    }

    MSG_ReadShort(msg); // peer-advertised window size
    const int fragmentSize = MSG_ReadShort(msg);
    if (msg->overflowed || fragmentSize < 0 || fragmentSize > kFragmentSize
        || fragmentSize > msg->cursize - msg->readcount)
    {
        Com_PrintWarning(14, "CoD4x: ignored malformed reliable fragment (%d bytes)\n", fragmentSize);
        return;
    }
    if (acknowledge > channel.transmitAcknowledge)
        channel.nextAckTime = 0;
    channel.transmitAcknowledge = acknowledge;
    if (channel.transmitFrame < acknowledge)
        channel.transmitFrame = acknowledge;
    if (sequence == -1)
        return;
    if (sequence < channel.receiveSequence)
        return;

    Fragment &fragment = channel.receiveFragments[sequence % kFragmentCount];
    fragment.length = fragmentSize;
    MSG_ReadData(msg, fragment.data.data(), fragmentSize);
    fragment.acknowledge = sequence;
    channel.nextAckTime = 0;

    AppendContiguousFragments();
    ProcessLogicalMessages();
}

void Cod4x_ReliableFrame(int now)
{
    if (!channel.connected)
        return;
    channel.time = now;
    if (channel.nextAckTime <= now)
        TransmitNextFragment();
}

bool Cod4x_ReliableSendMessage(msg_t *msg)
{
    if (!channel.connected || !msg || msg->cursize < 4)
        return false;

    const int messageSize = msg->cursize - 4;
    msg->data[0] = static_cast<unsigned char>(messageSize);
    msg->data[1] = static_cast<unsigned char>(messageSize >> 8);
    msg->data[2] = static_cast<unsigned char>(messageSize >> 16);
    msg->data[3] = static_cast<unsigned char>(messageSize >> 24);

    const int fragmentsNeeded = (msg->cursize + kFragmentSize - 1) / kFragmentSize;
    if (channel.transmitSequence - channel.transmitAcknowledge + fragmentsNeeded > kFragmentCount)
        return false;

    int offset = 0;
    while (offset < msg->cursize)
    {
        const int length = std::min(kFragmentSize, msg->cursize - offset);
        Fragment &fragment = channel.transmitFragments[channel.transmitSequence % kFragmentCount];
        memcpy(fragment.data.data(), msg->data + offset, static_cast<size_t>(length));
        fragment.length = length;
        fragment.acknowledge = -1;
        ++channel.transmitSequence;
        offset += length;
    }
    channel.nextAckTime = 0;
    return true;
}
