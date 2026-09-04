// Native IPv4/UDP transport for the POSIX client.
//
// The original engine keeps one non-blocking UDP socket and multiplexes game
// packets through netadr_t.  Recreating that small system layer here lets the
// unmodified netchan and client connection state machines talk directly to
// Internet servers without Wine or another network proxy.

#include <qcommon/qcommon.h>
#include <qcommon/net_chan_mp.h>

#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

namespace
{
constexpr int kDefaultPort = 28960;
constexpr int kPortAttempts = 10;

int s_ipSocket = -1;
bool s_tracePackets = false;
unsigned int s_traceSends = 0;
unsigned int s_traceReceives = 0;

void TracePacket(const char *direction, const sockaddr_in &address,
                 const unsigned char *data, int length, ssize_t result,
                 unsigned int *counter)
{
    if (!s_tracePackets || (*counter)++ >= 128)
        return;

    char ip[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &address.sin_addr, ip, sizeof(ip));

    char payload[65]{};
    int payloadLength = 0;
    // Connectionless packets begin with four 0xff bytes.  Showing their
    // printable command makes native client/server handshakes diagnosable
    // without dumping gameplay payloads or authentication material.
    if (data && length >= 4 && data[0] == 0xff && data[1] == 0xff
        && data[2] == 0xff && data[3] == 0xff)
    {
        for (int i = 4; i < length && payloadLength < 64; ++i)
        {
            const unsigned char c = data[i];
            if (c == 0 || c == '\n' || c == '\r' || c == ' ' || c == '\t')
                break;
            payload[payloadLength++] = (c >= 32 && c < 127)
                ? static_cast<char>(c) : '.';
        }
    }

    Com_Printf(16, "[native-net] %s %d bytes %s %s:%u%s%s%s\n",
               direction, length, result >= 0 ? "at" : "failed at", ip,
               static_cast<unsigned int>(ntohs(address.sin_port)),
               payloadLength ? " oob=\"" : "",
               payloadLength ? payload : "", payloadLength ? "\"" : "");
}

void SockaddrToNetadr(const sockaddr_in &from, netadr_t *to)
{
    std::memset(to, 0, sizeof(*to));
    to->type = NA_IP;
    std::memcpy(to->ip, &from.sin_addr.s_addr, sizeof(to->ip));
    to->port = from.sin_port;
}

void NetadrToSockaddr(const netadr_t &from, sockaddr_in *to)
{
    std::memset(to, 0, sizeof(*to));
    to->sin_family = AF_INET;
    to->sin_port = from.port;
    if (from.type == NA_BROADCAST)
        to->sin_addr.s_addr = htonl(INADDR_BROADCAST);
    else
        std::memcpy(&to->sin_addr.s_addr, from.ip, sizeof(from.ip));
}

int OpenUdpSocket(int requestedPort)
{
    const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0)
    {
        Com_PrintWarning(16, "WARNING: UDP socket: %s\n", std::strerror(errno));
        return -1;
    }

    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
    {
        Com_PrintWarning(16, "WARNING: UDP non-blocking mode: %s\n", std::strerror(errno));
        close(fd);
        return -1;
    }

    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, sizeof(enabled)) < 0)
    {
        Com_PrintWarning(16, "WARNING: UDP broadcast option: %s\n", std::strerror(errno));
        close(fd);
        return -1;
    }

    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons(static_cast<unsigned short>(requestedPort));
    if (bind(fd, reinterpret_cast<const sockaddr *>(&local), sizeof(local)) < 0)
    {
        close(fd);
        return -1;
    }

    return fd;
}
} // namespace

void NET_Init()
{
    if (s_ipSocket >= 0)
        return;

    s_tracePackets = std::getenv("KISAK_NET_TRACE") != nullptr;
    s_traceSends = 0;
    s_traceReceives = 0;

    const dvar_t *netPort = Dvar_RegisterInt(
        "net_port", kDefaultPort, 0, 65535, DVAR_LATCH,
        "Local UDP port used by the native network transport");
    const int firstPort = netPort ? netPort->current.integer : kDefaultPort;

    int boundPort = firstPort;
    for (int attempt = 0; attempt < kPortAttempts; ++attempt)
    {
        boundPort = firstPort + attempt;
        s_ipSocket = OpenUdpSocket(boundPort);
        if (s_ipSocket >= 0)
            break;
    }

    // A client does not require a predictable source port.  Retain local
    // server compatibility by preferring net_port, then fall back to an
    // ephemeral port if all ten traditional ports are occupied.
    if (s_ipSocket < 0)
    {
        boundPort = 0;
        s_ipSocket = OpenUdpSocket(boundPort);
    }

    if (s_ipSocket < 0)
    {
        Com_PrintWarning(16, "WARNING: Native UDP networking is unavailable\n");
        return;
    }

    if (boundPort == 0)
    {
        sockaddr_in local{};
        socklen_t localLength = sizeof(local);
        if (getsockname(s_ipSocket, reinterpret_cast<sockaddr *>(&local), &localLength) == 0)
            boundPort = ntohs(local.sin_port);
    }

    Com_Printf(16, "Native UDP initialized on port %d\n", boundPort);
}

qboolean Sys_StringToAdr(const char *name, netadr_t *address)
{
    if (!name || !*name || !address)
        return qfalse;

    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;

    addrinfo *results = nullptr;
    const int error = getaddrinfo(name, nullptr, &hints, &results);
    if (error != 0 || !results)
    {
        if (results)
            freeaddrinfo(results);
        return qfalse;
    }

    const auto *resolved = reinterpret_cast<const sockaddr_in *>(results->ai_addr);
    SockaddrToNetadr(*resolved, address);
    freeaddrinfo(results);
    return qtrue;
}

char Sys_SendPacket(int length, unsigned char *data, netadr_t to)
{
    if (s_ipSocket < 0)
        return 0;
    if (to.type != NA_IP && to.type != NA_BROADCAST)
    {
        Com_PrintError(16, "Sys_SendPacket: bad address type %d\n", static_cast<int>(to.type));
        return 0;
    }

    sockaddr_in destination{};
    NetadrToSockaddr(to, &destination);
    const ssize_t sent = sendto(
        s_ipSocket,
        data,
        static_cast<size_t>(length),
        0,
        reinterpret_cast<const sockaddr *>(&destination),
        sizeof(destination));
    TracePacket("send", destination, data, length, sent, &s_traceSends);
    if (sent >= 0)
        return 1;

    if (errno == EAGAIN || errno == EWOULDBLOCK ||
        (errno == EADDRNOTAVAIL && to.type == NA_BROADCAST))
        return 1;

    Com_PrintError(16, "Sys_SendPacket: %s\n", std::strerror(errno));
    return 0;
}

qboolean Sys_GetPacket(netadr_t *from, msg_t *message)
{
    if (s_ipSocket < 0 || !from || !message || !message->data || message->maxsize <= 0)
        return qfalse;

    sockaddr_in source{};
    socklen_t sourceLength = sizeof(source);
    const ssize_t received = recvfrom(
        s_ipSocket,
        message->data,
        static_cast<size_t>(message->maxsize),
        0,
        reinterpret_cast<sockaddr *>(&source),
        &sourceLength);

    if (received < 0)
    {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != ECONNREFUSED)
            Com_PrintError(16, "NET_GetPacket: %s\n", std::strerror(errno));
        return qfalse;
    }

    TracePacket("recv", source, message->data, static_cast<int>(received),
                received, &s_traceReceives);

    SockaddrToNetadr(source, from);
    message->readcount = 0;
    if (received >= message->maxsize)
    {
        Com_Printf(16, "Oversize packet from %s\n", NET_AdrToString(*from));
        return qfalse;
    }

    message->cursize = static_cast<int>(received);
    return qtrue;
}

bool Sys_IsLANAddress_IgnoreSubnet(netadr_t address)
{
    if (address.type == NA_LOOPBACK || address.type == NA_BOT)
        return true;
    if (address.type != NA_IP)
        return false;

    return address.ip[0] == 10
        || address.ip[0] == 127
        || (address.ip[0] == 169 && address.ip[1] == 254)
        || (address.ip[0] == 172 && (address.ip[1] & 0xf0) == 16)
        || (address.ip[0] == 192 && address.ip[1] == 168);
}

bool Sys_IsLANAddress(netadr_t address)
{
    if (Sys_IsLANAddress_IgnoreSubnet(address))
        return true;
    if (address.type != NA_IP)
        return false;

    uint32_t remoteAddress;
    std::memcpy(&remoteAddress, address.ip, sizeof(remoteAddress));

    ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0)
        return false;

    bool isLocalSubnet = false;
    for (const ifaddrs *interface = interfaces; interface; interface = interface->ifa_next)
    {
        if (!interface->ifa_addr || !interface->ifa_netmask
            || interface->ifa_addr->sa_family != AF_INET)
        {
            continue;
        }

        const auto *local = reinterpret_cast<const sockaddr_in *>(interface->ifa_addr);
        const auto *mask = reinterpret_cast<const sockaddr_in *>(interface->ifa_netmask);
        if ((remoteAddress & mask->sin_addr.s_addr)
            == (local->sin_addr.s_addr & mask->sin_addr.s_addr))
        {
            isLocalSubnet = true;
            break;
        }
    }

    freeifaddrs(interfaces);
    return isLocalSubnet;
}

void Sys_ShowIP()
{
    ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0)
        return;

    char address[INET_ADDRSTRLEN];
    for (const ifaddrs *interface = interfaces; interface; interface = interface->ifa_next)
    {
        if (!interface->ifa_addr || interface->ifa_addr->sa_family != AF_INET)
            continue;
        const auto *ipv4 = reinterpret_cast<const sockaddr_in *>(interface->ifa_addr);
        if (inet_ntop(AF_INET, &ipv4->sin_addr, address, sizeof(address)))
            Com_Printf(16, "IP: %s (%s)\n", address, interface->ifa_name);
    }
    freeifaddrs(interfaces);
}
