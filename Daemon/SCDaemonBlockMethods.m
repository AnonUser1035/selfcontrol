//
//  SCDaemonBlockMethods.m
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCDaemonBlockMethods.h"
#import "SCSettings.h"
#import "SCHelperToolUtilities.h"
#import "PacketFilter.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"
#import "SCScheduleUtilities.h"

NSTimeInterval METHOD_LOCK_TIMEOUT = 5.0;
NSTimeInterval CHECKUP_LOCK_TIMEOUT = 0.5; // use a shorter lock timeout for checkups, because we'd prefer not to have tons pile up

@implementation SCDaemonBlockMethods

+ (NSLock*)daemonMethodLock {
    static NSLock* lock = nil;
    if (lock == nil) {
        lock = [[NSLock alloc] init];
    }
    return lock;
}

+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply timeout:(NSTimeInterval)timeout {
    // only run one request at a time, so we avoid weird situations like trying to run a checkup while we're starting a block
    if (![self.daemonMethodLock lockBeforeDate: [NSDate dateWithTimeIntervalSinceNow: timeout]]) {
        // if we couldn't get a lock within 10 seconds, something is weird
        // but we probably shouldn't still run, because that's just unexpected at that point
        // don't capture this error on Sentry because it's very usual for checkups to timeout
        NSError* err = [SCErr errorWithCode: 300];
        NSLog(@"ERROR: Timed out acquiring request lock (after %f seconds)", timeout);

        if (reply != nil) {
            reply(err);
        }
        return NO;
    }
    return YES;
}
+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply {
    return [self lockOrTimeout: reply timeout: METHOD_LOCK_TIMEOUT];
}


+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    // we reset at the _end_ of every method, but we'll also reset at the _start_ here
    // because startBlock can sometimes take a while, and it'd be a shame if the daemon killed itself
    // before we were done
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    
    [SCSentry addBreadcrumb: @"Daemon method startBlock called" category: @"daemon"];
    
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"ERROR: Can't start block since a block is already running");
        NSError* err = [SCErr errorWithCode: 301];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // clear any legacy block information - no longer useful and could potentially confuse things
    // but first, copy it over one more time (this should've already happened once in the app, but you never know)
    if ([SCMigrationUtilities legacySettingsFoundForUser: controllingUID]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults: controllingUID];
        [SCMigrationUtilities clearLegacySettingsForUser: controllingUID];
        
        // if we had legacy settings, there's a small chance the old helper tool could still be around
        // make sure it's dead and gone
        [LaunchctlHelper unloadLaunchdJobWithPlistAt: @"/Library/LaunchDaemons/org.eyebeam.SelfControl.plist"];
    }

    NSError* startErr = [self startBlockWhileLockedWithBlocklist: blocklist isAllowlist: isAllowlist endDate: endDate blockSettings: blockSettings];
    reply(startErr);
    [self.daemonMethodLock unlock];
}

// shared by the startBlock XPC method and the scheduler. Caller must hold daemonMethodLock
// and must already have checked that no block is running.
+ (NSError*)startBlockWhileLockedWithBlocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings {
    SCSettings* settings = [SCSettings sharedSettings];
    // update SCSettings with the blocklist and end date that've been requested
    [settings setValue: blocklist forKey: @"ActiveBlocklist"];
    [settings setValue: @(isAllowlist) forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: endDate forKey: @"BlockEndDate"];
    
    // update all the settings for the block, which we're basically just copying from defaults to settings
    [settings setValue: blockSettings[@"ClearCaches"] forKey: @"ClearCaches"];
    [settings setValue: blockSettings[@"AllowLocalNetworks"] forKey: @"AllowLocalNetworks"];
    [settings setValue: blockSettings[@"EvaluateCommonSubdomains"] forKey: @"EvaluateCommonSubdomains"];
    [settings setValue: blockSettings[@"IncludeLinkedDomains"] forKey: @"IncludeLinkedDomains"];
    [settings setValue: blockSettings[@"BlockSoundShouldPlay"] forKey: @"BlockSoundShouldPlay"];
    [settings setValue: blockSettings[@"BlockSound"] forKey: @"BlockSound"];
    [settings setValue: blockSettings[@"EnableErrorReporting"] forKey: @"EnableErrorReporting"];

    if(([blocklist count] <= 0 && !isAllowlist) || [SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"ERROR: Blocklist is empty, or block end date is in the past");
        NSLog(@"Block End Date: %@ (%@), vs now is %@", [settings valueForKey: @"BlockEndDate"], [[settings valueForKey: @"BlockEndDate"] class], [NSDate date]);
        NSError* err = [SCErr errorWithCode: 302];
        [SCSentry captureError: err];
        return err;
    }

    NSLog(@"Adding firewall rules...");
    [SCHelperToolUtilities installBlockRulesFromSettings];
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    
    NSError* syncErr = [settings syncSettingsAndWait: 5]; // synchronize ASAP since BlockIsRunning is a really important one
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after starting block", syncErr);
        [SCSentry captureError: syncErr];
    }

    NSLog(@"Firewall rules added!");
    
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon added block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully added.");

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [[SCDaemon sharedDaemon] startCheckupTimer];
    return nil;
}

+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlocklist called" category: @"daemon"];
    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 303];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update blocklist since block isn't running");
        NSError* err = [SCErr errorWithCode: 304];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
        
    if ([settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        NSLog(@"ERROR: Attempting to update active blocklist, but this is not possible with an allowlist block");
        NSError* err = [SCErr errorWithCode: 305];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"];
    NSMutableArray* added = [NSMutableArray arrayWithArray: newBlocklist];
    [added removeObjectsInArray: activeBlocklist];
    NSMutableArray* removed = [NSMutableArray arrayWithArray: activeBlocklist];
    [removed removeObjectsInArray: newBlocklist];
    
    // throw a warning if something got removed for some reason, since we ignore them
    if (removed.count > 0) {
        NSLog(@"WARNING: Active blocklist has removed items; these will not be updated. Removed items are %@", removed);
    }
    
    BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist: [settings boolForKey: @"ActiveBlockAsWhitelist"]
                                                            allowLocal: [settings boolForKey: @"AllowLocalNetworks"]
                                               includeCommonSubdomains: [settings boolForKey: @"EvaluateCommonSubdomains"]
                                                  includeLinkedDomains: [settings boolForKey: @"IncludeLinkedDomains"]];
    [blockManager enterAppendMode];
    [blockManager addBlockEntriesFromStrings: added];
    [blockManager finishAppending];
    
    [settings setValue: newBlocklist forKey: @"ActiveBlocklist"];
    
    // make sure everyone knows about our new list
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after updating blocklist", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon updated blocklist successfully" category: @"daemon"];
    NSLog(@"INFO: Blocklist successfully updated.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlockEndDate called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 306];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date since block isn't running");
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    
    // this can only be used to *extend* the block end date - not shorten it!
    // and we also won't let them extend by more than 24 hours at a time, for safety...
    // TODO: they should be able to extend up to MaxBlockLength minutes, right?
    NSDate* currentEndDate = [settings valueForKey: @"BlockEndDate"];
    if ([newEndDate timeIntervalSinceDate: currentEndDate] < 0) {
        NSLog(@"ERROR: Can't update block end date to an earlier date");
        NSError* err = [SCErr errorWithCode: 308];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return; // fork: upstream fell through and applied the change anyway
    }
    if ([newEndDate timeIntervalSinceDate: currentEndDate] > 86400) { // 86400 seconds = 1 day
        NSLog(@"ERROR: Can't extend block end date by more than 1 day at a time");
        NSError* err = [SCErr errorWithCode: 309];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return; // fork: upstream fell through and applied the change anyway
    }
    
    [settings setValue: newEndDate forKey: @"BlockEndDate"];
    
    // make sure everyone knows about our new end date
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after extending block", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    [SCSentry addBreadcrumb: @"Daemon extended block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully extended.");
    reply(nil);
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (void)checkupBlock {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkupBlock called" category: @"daemon"];

    NSTimeInterval integrityCheckIntervalSecs = 15.0;
    static NSDate* lastBlockIntegrityCheck;
    if (lastBlockIntegrityCheck == nil) {
        lastBlockIntegrityCheck = [NSDate distantPast];
    }

    BOOL shouldRunIntegrityCheck = NO;
    if(![SCBlockUtilities anyBlockIsRunning]) {
        // No block appears to be running at all in our settings.
        // Most likely, the user removed it trying to get around the block. Boo!
        // but for safety and to avoid permablocks (we no longer know when the block should end)
        // we should clear the block now.
        // but let them know that we noticed their (likely) cheating and we're not happy!
        NSLog(@"INFO: Checkup ran, no active block found.");
        
        [SCSentry captureMessage: @"Checkup ran and no active block found! Removing block, tampering suspected..."];
        
        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];
        
        // Temporarily disabled the TamperingDetection flag because it was sometimes causing false positives
        // (i.e. people having the background set repeatedly despite no attempts to cheat)
        // We will try to bring this feature back once we can debug it
        // GitHub issue: https://github.com/SelfControlApp/selfcontrol/issues/621
        // [settings setValue: @YES forKey: @"TamperingDetected"];
        //        [settings synchronizeSettings];
        //
        
        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    } else if ([SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"INFO: Checkup ran, block expired, removing block.");
        
        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];

        [SCSentry addBreadcrumb: @"Daemon found and cleared expired block" category: @"daemon"];

        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    } else if ([[NSDate date] timeIntervalSinceDate: lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
        lastBlockIntegrityCheck = [NSDate date];
        // The block is still on.  Every once in a while, we should
        // check if anybody removed our rules, and if so
        // re-add them.
        shouldRunIntegrityCheck = YES;
    }
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
    
    // if we need to run an integrity check, we need to do it at the very end after we give up our lock
    // because checkBlockIntegrity requests its own lock, and we don't want it to deadlock
    if (shouldRunIntegrityCheck) {
        [SCDaemonBlockMethods checkBlockIntegrity];
    }
}

+ (void)checkBlockIntegrity {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkBlockIntegrity called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    PacketFilter* pf = [[PacketFilter alloc] init];
    HostFileBlockerSet* hostFileBlockerSet = [[HostFileBlockerSet alloc] init];
    if(![pf containsSelfControlBlock] || (![settings boolForKey: @"ActiveBlockAsWhitelist"] && ![hostFileBlockerSet.defaultBlocker containsSelfControlBlock])) {
        NSLog(@"INFO: Block is missing in PF or hosts, re-adding...");
        // The firewall is missing at least the block header.  Let's clear everything
        // before we re-add to make sure everything goes smoothly.

        [pf stopBlock: false];

        [hostFileBlockerSet removeSelfControlBlock];
        BOOL success = [hostFileBlockerSet writeNewFileContents];
        // Revert the host file blocker's file contents to disk so we can check
        // whether or not it still contains the block after our write (aka we messed up).
        [hostFileBlockerSet revertFileContentsToDisk];
        if(!success || [hostFileBlockerSet.defaultBlocker containsSelfControlBlock]) {
            NSLog(@"WARNING: Error removing host file block.  Attempting to restore backup.");

            if([hostFileBlockerSet restoreBackupHostsFile])
                NSLog(@"INFO: Host file backup restored.");
            else
                NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
        }

        // Get rid of the backup file since we're about to make a new one.
        [hostFileBlockerSet deleteBackupHostsFile];

        // Perform the re-add of the rules
        [SCHelperToolUtilities installBlockRulesFromSettings];
        
        [SCHelperToolUtilities clearCachesIfRequested];

        [SCSentry addBreadcrumb: @"Daemon found compromised block integrity and re-added rules" category: @"daemon"];
        NSLog(@"INFO: Integrity check ran; readded block rules.");
    } else NSLog(@"INFO: Integrity check ran; no action needed.");

    [self.daemonMethodLock unlock];
}

#pragma mark - Scheduled blocks (fork)

+ (void)updateSchedules:(NSArray<NSDictionary*>*)schedules requirePasswordlessChange:(BOOL)requirePasswordless reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    [[SCDaemon sharedDaemon] resetInactivityTimer];

    SCSettings* settings = [SCSettings sharedSettings];
    NSDate* now = [NSDate date];
    NSArray* currentSchedules = [settings valueForKey: @"Schedules"];
    NSError* err = [SCScheduleUtilities validateSchedules: schedules];
    if (err == nil) {
        err = [SCScheduleUtilities validateChangeFromSchedules: currentSchedules toSchedules: schedules atDate: now];
    }
    if (err == nil && requirePasswordless && ![SCScheduleUtilities changeIsPasswordlessFromSchedules: currentSchedules toSchedules: schedules atDate: now reason: nil]) {
        err = [NSError errorWithDomain: SCScheduleErrorDomain code: 31 userInfo: @{ NSLocalizedDescriptionKey: @"Your schedules changed while this was being saved. Please try again." }];
    }
    if (err != nil) {
        NSLog(@"ERROR: Rejected schedule update: %@", err.localizedDescription);
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    [settings setValue: schedules forKey: @"Schedules"];
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after updating schedules", syncErr);
    }
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    NSLog(@"INFO: Schedules updated (%lu schedules).", (unsigned long)schedules.count);
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];

    // one of the new schedules might be active right now
    [[SCDaemon sharedDaemon] checkSchedulesSoon];
}

+ (void)checkSchedules {
    SCSettings* settings = [SCSettings sharedSettings];
    NSArray* schedules = [settings valueForKey: @"Schedules"];
    if (![schedules isKindOfClass: [NSArray class]] || schedules.count == 0) return;

    NSDate* now = [NSDate date];
    BOOL needsPruning = ![[SCScheduleUtilities schedulesByPruningExpired: schedules atDate: now] isEqualToArray: schedules];
    NSArray<NSDictionary*>* activeSchedules = [SCScheduleUtilities activeSchedules: schedules atDate: now];
    if (activeSchedules.count == 0 && !needsPruning) return;

    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: METHOD_LOCK_TIMEOUT]) {
        return;
    }
    [[SCDaemon sharedDaemon] resetInactivityTimer];

    // one-off schedules are deleted once their window has passed, and old skipped days are forgotten
    schedules = [settings valueForKey: @"Schedules"];
    NSArray* prunedSchedules = [SCScheduleUtilities schedulesByPruningExpired: schedules atDate: now];
    if (![prunedSchedules isEqualToArray: schedules]) {
        NSLog(@"INFO: Removing %lu finished one-off schedule(s) and old skipped days", (unsigned long)(schedules.count - prunedSchedules.count));
        [settings setValue: prunedSchedules forKey: @"Schedules"];
        NSError* syncErr = [settings syncSettingsAndWait: 5];
        if (syncErr != nil) {
            NSLog(@"WARNING: Sync failed or timed out with error %@ after pruning schedules", syncErr);
        }
        [SCHelperToolUtilities sendConfigurationChangedNotification];
    }
    activeSchedules = [SCScheduleUtilities activeSchedules: prunedSchedules atDate: now];
    if (activeSchedules.count == 0) {
        [self.daemonMethodLock unlock];
        return;
    }

    // combine every active schedule: block the union of their sites until the latest window ends
    NSDate* endDate = nil;
    NSMutableOrderedSet<NSString*>* sites = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary* blockSettings = [NSMutableDictionary dictionary];
    for (NSDictionary* schedule in activeSchedules) {
        NSDate* windowEnd = [SCScheduleUtilities activeWindowEndForSchedule: schedule atDate: now];
        if (windowEnd == nil) continue;
        if (endDate == nil || [windowEnd compare: endDate] == NSOrderedDescending) {
            endDate = windowEnd;
        }
        [sites addObjectsFromArray: schedule[SCScheduleKeyBlocklist]];
        NSDictionary* scheduleBlockSettings = schedule[SCScheduleKeyBlockSettings];
        for (NSString* key in scheduleBlockSettings) {
            if (blockSettings[key] == nil) blockSettings[key] = scheduleBlockSettings[key];
        }
    }
    for (NSString* key in @[@"ClearCaches", @"AllowLocalNetworks", @"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"BlockSoundShouldPlay", @"BlockSound", @"EnableErrorReporting"]) {
        if (blockSettings[key] == nil) blockSettings[key] = [settings valueForKey: key];
    }

    if (endDate == nil || sites.count == 0 || [SCBlockUtilities legacyBlockIsRunning]) {
        [self.daemonMethodLock unlock];
        return;
    }

    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"INFO: Schedule window is active, starting scheduled block until %@", endDate);
        NSError* err = [self startBlockWhileLockedWithBlocklist: sites.array isAllowlist: NO endDate: endDate blockSettings: blockSettings];
        if (err != nil) {
            NSLog(@"ERROR: Failed to start scheduled block with error %@", err);
        }
        [self.daemonMethodLock unlock];
        return;
    }

    // a block is already running (manual or scheduled): make sure it covers the schedule
    BOOL changed = NO;
    BOOL addedSites = NO;
    if (![settings boolForKey: @"ActiveBlockAsWhitelist"]) {
        NSArray* activeBlocklist = [settings valueForKey: @"ActiveBlocklist"] ?: @[];
        NSMutableOrderedSet<NSString*>* missing = [sites mutableCopy];
        [missing removeObjectsInArray: activeBlocklist];
        if (missing.count > 0) {
            NSLog(@"INFO: Adding %lu scheduled sites to the running block", (unsigned long)missing.count);
            BlockManager* blockManager = [[BlockManager alloc] initAsAllowlist: NO
                                                                    allowLocal: [settings boolForKey: @"AllowLocalNetworks"]
                                                       includeCommonSubdomains: [settings boolForKey: @"EvaluateCommonSubdomains"]
                                                          includeLinkedDomains: [settings boolForKey: @"IncludeLinkedDomains"]];
            [blockManager enterAppendMode];
            [blockManager addBlockEntriesFromStrings: missing.array];
            [blockManager finishAppending];
            [settings setValue: [activeBlocklist arrayByAddingObjectsFromArray: missing.array] forKey: @"ActiveBlocklist"];
            changed = addedSites = YES;
        }
    }
    NSDate* currentEndDate = [settings valueForKey: @"BlockEndDate"];
    if (![currentEndDate isKindOfClass: [NSDate class]] || [currentEndDate compare: endDate] == NSOrderedAscending) {
        NSLog(@"INFO: Extending running block to the end of the schedule window (%@)", endDate);
        [settings setValue: endDate forKey: @"BlockEndDate"];
        changed = YES;
    }

    if (changed) {
        NSError* syncErr = [settings syncSettingsAndWait: 5];
        if (syncErr != nil) {
            NSLog(@"WARNING: Sync failed or timed out with error %@ after applying schedule", syncErr);
        }
        [SCHelperToolUtilities sendConfigurationChangedNotification];
        if (addedSites) {
            [SCHelperToolUtilities clearCachesIfRequested];
        }
    }

    [self.daemonMethodLock unlock];
}

@end
