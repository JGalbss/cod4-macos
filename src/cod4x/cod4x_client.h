#pragma once

// The public CoD4x client reports protocol 21 for the 21.x family.  Keep the
// sub-version separate: development servers may enforce it, while release
// servers negotiate on the integer protocol.
constexpr int KISAK_COD4X_PROTOCOL_VERSION = 21;
constexpr const char *KISAK_COD4X_CLIENT_VERSION = "21.3";

void Cod4x_Init();
bool Cod4x_IsEnabled();
bool Cod4x_AcceptsServerProtocol(int protocol, int stockProtocol);

// Connection negotiation.  A challenge containing "xproto" selects the
// current CoD4x wire protocol; an ordinary challenge keeps stock IW3 working.
void Cod4x_OnChallengeResponse();
bool Cod4x_UseExtendedProtocol();
const char *Cod4x_GetGuid();

// If KISAK_COD4X_PASSWORD_FILE names a readable one-line file, copy its value
// into the ordinary userinfo password dvar without logging the secret.
void Cod4x_ApplyPasswordFile();

// Protocol-21 state carried outside the stock IW3 client structures.
int Cod4x_GetServerConfigDataSequence();
void Cod4x_SetServerConfigDataSequence(int sequence);
void Cod4x_ExecuteReliableMessage(struct msg_t *msg);

// Query CoD4x's TCP master protocol and publish the IPv4 results through the
// engine's existing global-server list.  The stock master uses a different,
// UDP-only response format, so it remains available as a fallback.
bool Cod4x_QueryMasterServers(const char *keywords);
