#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

#include "posix/posix_updater.h"

#include <cstdio>

namespace
{

SPUStandardUpdaterController *g_updaterController = nil;

bool IsValidHttpsFeed(NSString *value)
{
    if (![value isKindOfClass:NSString.class] || value.length == 0)
        return false;

    NSURLComponents *const components = [NSURLComponents componentsWithString:value];
    return [components.scheme.lowercaseString isEqualToString:@"https"]
        && components.host.length > 0
        && components.user.length == 0
        && components.password.length == 0;
}

bool IsValidEd25519PublicKey(NSString *value)
{
    if (![value isKindOfClass:NSString.class] || value.length == 0)
        return false;

    NSData *const decoded = [[NSData alloc] initWithBase64EncodedString:value options:0];
    return decoded.length == 32;
}

NSMenu *ApplicationMenu()
{
    NSMenu *mainMenu = NSApp.mainMenu;
    if (!mainMenu)
    {
        mainMenu = [[NSMenu alloc] initWithTitle:@""];
        NSApp.mainMenu = mainMenu;
    }

    NSMenuItem *applicationMenuItem = mainMenu.itemArray.firstObject;
    if (!applicationMenuItem)
    {
        applicationMenuItem = [[NSMenuItem alloc] initWithTitle:@"jgalbs cod4"
                                                        action:nil
                                                 keyEquivalent:@""];
        [mainMenu addItem:applicationMenuItem];
    }

    NSMenu *applicationMenu = applicationMenuItem.submenu;
    if (!applicationMenu)
    {
        applicationMenu = [[NSMenu alloc] initWithTitle:@"jgalbs cod4"];
        applicationMenuItem.submenu = applicationMenu;
    }
    return applicationMenu;
}

void InstallCheckForUpdatesMenuItem()
{
    NSMenu *const applicationMenu = ApplicationMenu();
    constexpr NSInteger kUpdaterMenuTag = 0x434F4434; // "COD4"

    NSMenuItem *menuItem = [applicationMenu itemWithTag:kUpdaterMenuTag];
    if (!menuItem)
    {
        menuItem = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                             action:@selector(checkForUpdates:)
                                      keyEquivalent:@""];
        menuItem.tag = kUpdaterMenuTag;

        // Keep Quit at the bottom if SDL/AppKit already installed it.
        NSInteger quitIndex = NSNotFound;
        for (NSInteger index = 0; index < applicationMenu.numberOfItems; ++index)
        {
            NSMenuItem *const candidate = [applicationMenu itemAtIndex:index];
            if (candidate.action == @selector(terminate:))
            {
                quitIndex = index;
                break;
            }
        }
        if (quitIndex != NSNotFound)
        {
            [applicationMenu insertItem:menuItem atIndex:quitIndex];
            [applicationMenu insertItem:NSMenuItem.separatorItem atIndex:quitIndex + 1];
        }
        else
        {
            if (applicationMenu.numberOfItems > 0
                && !applicationMenu.itemArray.lastObject.isSeparatorItem)
            {
                [applicationMenu addItem:NSMenuItem.separatorItem];
            }
            [applicationMenu addItem:menuItem];
        }
    }

    menuItem.target = g_updaterController;
    menuItem.action = @selector(checkForUpdates:);
}

} // namespace

namespace posix_updater
{

void Initialize()
{
    if (![NSThread isMainThread])
    {
        std::fprintf(stderr, "[updater] initialization refused off the macOS main thread\n");
        return;
    }
    if (g_updaterController)
        return;

    NSBundle *const bundle = NSBundle.mainBundle;
    NSDictionary<NSString *, id> *const info = bundle.infoDictionary;
    NSString *const feedURL = info[@"SUFeedURL"];
    NSString *const publicKey = info[@"SUPublicEDKey"];
    const bool signedFeedRequired = [info[@"SURequireSignedFeed"] boolValue];
    const bool verifyBeforeExtraction = [info[@"SUVerifyUpdateBeforeExtraction"] boolValue];
    const bool automaticChecksEnabled = [info[@"SUEnableAutomaticChecks"] boolValue];
    const bool isApplicationBundle = [bundle.bundleURL.pathExtension.lowercaseString
        isEqualToString:@"app"];

    if (!isApplicationBundle
        || !IsValidHttpsFeed(feedURL)
        || !IsValidEd25519PublicKey(publicKey)
        || !signedFeedRequired
        || !verifyBeforeExtraction)
    {
        std::fprintf(stderr,
            "[updater] disabled: package must be an .app with HTTPS SUFeedURL, a 32-byte "
            "SUPublicEDKey, SURequireSignedFeed=true, and SUVerifyUpdateBeforeExtraction=true\n");
        return;
    }

    g_updaterController = [[SPUStandardUpdaterController alloc]
        initWithStartingUpdater:YES
        updaterDelegate:nil
        userDriverDelegate:nil];
    InstallCheckForUpdatesMenuItem();

    std::fprintf(stdout,
        automaticChecksEnabled
            ? "[updater] Sparkle enabled; scheduled and manual checks are available\n"
            : "[updater] Sparkle enabled; manual checks are available\n");
    std::fflush(stdout);
}

} // namespace posix_updater
