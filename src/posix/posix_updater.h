#pragma once

namespace posix_updater
{

// Starts the configured Sparkle updater and adds a native application-menu
// item. This must be called once from the macOS main thread after NSApp exists.
// A production configuration gate in the implementation keeps the updater
// inert unless the bundle supplies an HTTPS feed, EdDSA public key, and signed
// feed/pre-extraction verification settings.
void Initialize();

} // namespace posix_updater
