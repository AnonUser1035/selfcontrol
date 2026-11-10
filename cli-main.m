//
//  cli-main.m
//  SelfControl
//
//  Created by Charlie Stigler on 2/4/09.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "PacketFilter.h"
#import "SCHelperToolUtilities.h"
#import "SCSettings.h"
#import "SCXPCClient.h"
#import "SCBlockFileReaderWriter.h"
#import <sysexits.h>
#import "XPMArguments.h"
#import "SCScheduleUtilities.h"

#pragma mark - schedule subcommand (fork)

static void SCPrintScheduleUsage(void) {
    printf("Usage: selfcontrol-cli schedule <command> [<args>]\n\n");
    printf("    list\n");
    printf("        show all schedules\n\n");
    printf("    add --days <days> --start <time> --end <time> [--name <name>] [--sites <a.com,b.com> | --blocklist <file>]\n");
    printf("        days:  mon-fri, weekdays, weekends, daily, sat,sun, fri-mon, ...\n");
    printf("        times: 09:00, 9:30pm, 23:00. If end <= start, the block runs past midnight.\n");
    printf("        sites default to your current SelfControl blocklist.\n\n");
    printf("    remove <id|name>\n");
    printf("    enable <id|name>\n");
    printf("    disable <id|name>\n\n");
    printf("Schedules can't be removed, disabled or shortened while they're active.\n");
    printf("Changing schedules asks for an administrator password.\n");
}

static NSString* SCOptionValue(NSArray<NSString*>* args, NSString* name) {
    NSUInteger idx = [args indexOfObject: name];
    if (idx == NSNotFound || idx + 1 >= args.count) return nil;
    return args[idx + 1];
}

static NSDictionary* SCAppDefaults(void) {
    NSMutableDictionary* defaults = [SCConstants.defaultUserDefaults mutableCopy];
    NSDictionary* appDomain = [[NSUserDefaults standardUserDefaults] persistentDomainForName: @"org.eyebeam.SelfControl"];
    [defaults addEntriesFromDictionary: appDomain ?: @{}];
    return defaults;
}

static NSDictionary* SCFindSchedule(NSArray* schedules, NSString* query) {
    NSMutableArray* matches = [NSMutableArray array];
    for (NSDictionary* schedule in schedules) {
        NSString* scheduleID = schedule[SCScheduleKeyID];
        NSString* name = schedule[SCScheduleKeyName];
        if ([scheduleID caseInsensitiveCompare: query] == NSOrderedSame) return schedule;
        if ([[scheduleID lowercaseString] hasPrefix: [query lowercaseString]]
            || (name != nil && [name caseInsensitiveCompare: query] == NSOrderedSame)) {
            [matches addObject: schedule];
        }
    }
    if (matches.count == 1) return matches[0];
    if (matches.count > 1) fprintf(stderr, "\"%s\" matches more than one schedule; use more of the ID.\n", query.UTF8String);
    else fprintf(stderr, "No schedule matches \"%s\". Run `selfcontrol-cli schedule list`.\n", query.UTF8String);
    return nil;
}

// makes sure the daemon is installed, then sends the new schedules (asks for an admin password)
static int SCPushSchedules(NSArray* schedules) {
    NSError* validationErr = [SCScheduleUtilities validateSchedules: schedules];
    if (validationErr == nil) {
        validationErr = [SCScheduleUtilities validateChangeFromSchedules: [[SCSettings sharedSettings] valueForKey: @"Schedules"]
                                                             toSchedules: schedules
                                                                  atDate: [NSDate date]];
    }
    if (validationErr != nil) {
        fprintf(stderr, "Error: %s\n", validationErr.localizedDescription.UTF8String);
        return EX_DATAERR;
    }

    SCXPCClient* xpc = [SCXPCClient new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int result = EXIT_SUCCESS;

    [xpc ensureDaemonInstalled:^(NSError* installErr) {
        if (installErr != nil) {
            if (![SCMiscUtilities errorIsAuthCanceled: installErr]) {
                fprintf(stderr, "Error: couldn't install the SelfControl helper: %s\n", installErr.localizedDescription.UTF8String);
            } else {
                fprintf(stderr, "Cancelled.\n");
            }
            result = EX_SOFTWARE;
            dispatch_semaphore_signal(done);
            return;
        }
        [xpc updateSchedules: schedules reply:^(NSError* updateErr) {
            if (updateErr != nil) {
                if ([SCMiscUtilities errorIsAuthCanceled: updateErr]) {
                    fprintf(stderr, "Cancelled.\n");
                } else {
                    fprintf(stderr, "Error: %s\n", updateErr.localizedDescription.UTF8String);
                }
                result = EX_SOFTWARE;
            }
            dispatch_semaphore_signal(done);
        }];
    }];

    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) {
        [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
    }
    return result;
}

static void SCPrintSchedules(NSArray* schedules) {
    if (schedules.count == 0) {
        printf("No schedules. Add one with `selfcontrol-cli schedule add --days mon-fri --start 9:00 --end 17:00`.\n");
        return;
    }
    NSDate* now = [NSDate date];
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"EEE h:mm a";
    printf("%-9s %-9s %-26s %-34s %-6s %s\n", "ID", "STATUS", "DAYS", "TIME", "SITES", "NAME");
    for (NSDictionary* schedule in schedules) {
        NSString* status;
        NSDate* activeEnd = [SCScheduleUtilities activeWindowEndForSchedule: schedule atDate: now];
        if (![schedule[SCScheduleKeyEnabled] boolValue]) {
            status = @"off";
        } else if (activeEnd != nil) {
            status = @"ACTIVE";
        } else {
            status = @"on";
        }
        NSString* note = @"";
        if (activeEnd != nil) {
            note = [NSString stringWithFormat: @"  (until %@)", [formatter stringFromDate: activeEnd]];
        } else {
            NSDate* next = [SCScheduleUtilities nextWindowStartForSchedule: schedule afterDate: now];
            if (next != nil) note = [NSString stringWithFormat: @"  (next %@)", [formatter stringFromDate: next]];
        }
        printf("%-9s %-9s %-26s %-34s %-6lu %s%s\n",
               [[schedule[SCScheduleKeyID] substringToIndex: 8] lowercaseString].UTF8String,
               status.UTF8String,
               [SCScheduleUtilities daysDescriptionForSchedule: schedule].UTF8String,
               [SCScheduleUtilities timeDescriptionForSchedule: schedule].UTF8String,
               (unsigned long)[schedule[SCScheduleKeyBlocklist] count],
               [schedule[SCScheduleKeyName] ?: @"" UTF8String],
               note.UTF8String);
    }
}

static int SCRunScheduleCommand(NSArray<NSString*>* args) {
    NSString* command = args.count > 0 ? args[0] : @"list";
    NSArray* schedules = [[SCSettings sharedSettings] valueForKey: @"Schedules"];
    if (![schedules isKindOfClass: [NSArray class]]) schedules = @[];

    if ([command isEqualToString: @"list"]) {
        SCPrintSchedules(schedules);
        return EXIT_SUCCESS;
    }

    if ([command isEqualToString: @"add"]) {
        NSString* daysArg = SCOptionValue(args, @"--days");
        NSString* startArg = SCOptionValue(args, @"--start");
        NSString* endArg = SCOptionValue(args, @"--end");
        if (daysArg == nil || startArg == nil || endArg == nil) {
            SCPrintScheduleUsage();
            return EX_USAGE;
        }
        NSArray<NSNumber*>* weekdays = [SCScheduleUtilities weekdaysFromString: daysArg];
        if (weekdays == nil) {
            fprintf(stderr, "Error: couldn't understand days \"%s\" (try mon-fri, weekends, daily, sat,sun).\n", daysArg.UTF8String);
            return EX_USAGE;
        }
        NSInteger startMinute = [SCScheduleUtilities minuteFromTimeString: startArg];
        NSInteger endMinute = [SCScheduleUtilities minuteFromTimeString: endArg];
        if (startMinute < 0 || endMinute < 0) {
            fprintf(stderr, "Error: couldn't understand the start or end time (try 09:00 or 9:30pm).\n");
            return EX_USAGE;
        }

        NSDictionary* appDefaults = SCAppDefaults();
        NSArray* blocklist;
        NSString* sitesArg = SCOptionValue(args, @"--sites");
        NSString* blocklistPath = SCOptionValue(args, @"--blocklist");
        if (sitesArg != nil) {
            blocklist = [sitesArg componentsSeparatedByString: @","];
        } else if (blocklistPath != nil) {
            NSDictionary* fileContents = [SCBlockFileReaderWriter readBlocklistFromFile: [NSURL fileURLWithPath: blocklistPath]];
            if (fileContents == nil) {
                fprintf(stderr, "Error: couldn't read blocklist file %s\n", blocklistPath.UTF8String);
                return EX_NOINPUT;
            }
            blocklist = fileContents[@"Blocklist"];
        } else {
            blocklist = appDefaults[@"Blocklist"];
        }
        blocklist = [SCMiscUtilities cleanBlocklist: blocklist ?: @[]];

        NSMutableDictionary* blockSettings = [NSMutableDictionary dictionary];
        for (NSString* key in @[@"ClearCaches", @"AllowLocalNetworks", @"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"BlockSoundShouldPlay", @"BlockSound", @"EnableErrorReporting"]) {
            if (appDefaults[key] != nil) blockSettings[key] = appDefaults[key];
        }

        NSDictionary* schedule = [SCScheduleUtilities scheduleWithName: SCOptionValue(args, @"--name")
                                                              weekdays: weekdays
                                                           startMinute: startMinute
                                                             endMinute: endMinute
                                                             blocklist: blocklist
                                                         blockSettings: blockSettings];
        int result = SCPushSchedules([schedules arrayByAddingObject: schedule]);
        if (result == EXIT_SUCCESS) {
            printf("Added: %s, %lu sites\n", [SCScheduleUtilities displayNameForSchedule: schedule].UTF8String, (unsigned long)blocklist.count);
        }
        return result;
    }

    if ([@[@"remove", @"enable", @"disable"] containsObject: command]) {
        if (args.count < 2) {
            SCPrintScheduleUsage();
            return EX_USAGE;
        }
        NSDictionary* target = SCFindSchedule(schedules, args[1]);
        if (target == nil) return EX_DATAERR;

        NSMutableArray* updated = [NSMutableArray array];
        for (NSDictionary* schedule in schedules) {
            if (schedule != target) {
                [updated addObject: schedule];
            } else if (![command isEqualToString: @"remove"]) {
                NSMutableDictionary* changed = [schedule mutableCopy];
                changed[SCScheduleKeyEnabled] = @([command isEqualToString: @"enable"]);
                [updated addObject: changed];
            }
        }
        int result = SCPushSchedules(updated);
        if (result == EXIT_SUCCESS) {
            NSString* verb = [command isEqualToString: @"remove"] ? @"Removed" : ([command isEqualToString: @"enable"] ? @"Enabled" : @"Disabled");
            printf("%s: %s\n", verb.UTF8String, [SCScheduleUtilities displayNameForSchedule: target].UTF8String);
        }
        return result;
    }

    if ([@[@"help", @"--help", @"-h"] containsObject: command]) {
        SCPrintScheduleUsage();
        return EXIT_SUCCESS;
    }

    SCPrintScheduleUsage();
    return EX_USAGE;
}

// The main method which deals which most of the logic flow and execution of
// the CLI tool.
int main(int argc, char* argv[]) {
    [SCSentry startSentry: @"org.eyebeam.selfcontrol-cli"];

    @autoreleasepool {
        // fork: `selfcontrol-cli schedule ...` is handled separately from the legacy argument parser
        if (argc >= 2 && strcmp(argv[1], "schedule") == 0) {
            NSMutableArray<NSString*>* scheduleArgs = [NSMutableArray array];
            for (int i = 2; i < argc; i++) [scheduleArgs addObject: @(argv[i])];
            exit(SCRunScheduleCommand(scheduleArgs));
        }

        XPMArgumentSignature
          * controllingUIDSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[--uid]="],
          * startSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[start --start --install]"],
          * blocklistSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[--blocklist -b]="],
          * blockEndDateSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[--enddate -d]="],
          * blockSettingsSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[--settings -s]="],
          * removeSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[remove --remove]"],
          * printSettingsSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[print-settings --printsettings -p]"],
          * isRunningSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[is-running --isrunning -r]"],
          * versionSig = [XPMArgumentSignature argumentSignatureWithFormat:@"[version --version -v]"];
        NSArray * signatures = @[controllingUIDSig, startSig, blocklistSig, blockEndDateSig, blockSettingsSig, removeSig, printSettingsSig, isRunningSig, versionSig];
        XPMArgumentPackage * arguments = [[NSProcessInfo processInfo] xpmargs_parseArgumentsWithSignatures:signatures];
        
        // We'll need the controlling UID to know what settings to read
        // try reading it from the command-line, otherwise if we're not root we use the current uid
        uid_t controllingUID = (uid_t)[[arguments firstObjectForSignature: controllingUIDSig] intValue];
        if (controllingUID <= 0) {
            // for legacy reasons, we'll also take an unlabeled argument that looks like an UID
            // (this makes us backwards-compatible with SC versions pre-4.0)
            for (NSString* uncapturedArg in arguments.uncapturedValues) {
                NSRange range = [uncapturedArg rangeOfString: @"^[0-9]{3}$" options: NSRegularExpressionSearch];
                if (range.location != NSNotFound) {
                    controllingUID = (uid_t)[uncapturedArg intValue];
                }
            }
        }
        if (controllingUID <= 0) {
            controllingUID = getuid();
        }

        SCSettings* settings = [SCSettings sharedSettings];
        
        NSDictionary* defaultsDict;
        // if we're running as root/sudo and we have a controlling UID, use defaults for the controlling user (legacy behavior)
        // otherwise, just use the current user's defaults (modern behavior)
        if (geteuid() == 0 && controllingUID > 0) {
            defaultsDict = [SCMiscUtilities defaultsDictForUser: controllingUID];
        } else {
            NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
            [defaults registerDefaults: SCConstants.defaultUserDefaults];
            defaultsDict = defaults.dictionaryRepresentation;
        }
        
		if([arguments booleanValueForSignature: startSig]) {
            [SCSentry addBreadcrumb: @"CLI method --install called" category: @"cli"];

            if ([SCBlockUtilities anyBlockIsRunning]) {
                NSLog(@"ERROR: Block is already running");
                exit(EX_CONFIG);
            }

            NSArray* blocklist;
            NSDate* blockEndDate;
            BOOL blockAsWhitelist = NO;
            NSMutableDictionary* blockSettings;

            // there are two ways we can read in the core block parameters (Blocklist, BlockEndDate, BlockAsWhitelist):
            // 1) we can receive them as command-line arguments, including a path to a blocklist file
            // 2) we can read them from user defaults (for legacy support, don't encourage this)
            NSString* pathToBlocklistFile = [arguments firstObjectForSignature: blocklistSig];
            NSDate* blockEndDateArg = [[NSISO8601DateFormatter new] dateFromString: [arguments firstObjectForSignature: blockEndDateSig]];

            // if we didn't get a valid block end date in the future, try our next approach: legacy unlabeled arguments
            // this is for backwards compatibility. In SC pre-4.0, this used to be called as --install {uid} {pathToBlocklistFile} {blockEndDate}
            // we'll sidestep XPMArgumentParser here because the legacy stuff was dumber and just dealt with args by index
            if ((pathToBlocklistFile == nil || blockEndDateArg == nil || [blockEndDateArg timeIntervalSinceNow] < 1)
                && (argv[3] != NULL && argv[4] != NULL)) {
                
                pathToBlocklistFile = @(argv[3]);
                blockEndDateArg = [[NSISO8601DateFormatter new] dateFromString: @(argv[4])];
                NSLog(@"created legacy block end date %@ from %@", blockEndDateArg, @(argv[4]));
            }
            
            // if we got valid block arguments from the command-line, read in that file
            if (pathToBlocklistFile != nil && blockEndDateArg != nil && [blockEndDateArg timeIntervalSinceNow] >= 1) {
                blockEndDate = blockEndDateArg;
                NSDictionary* readProperties = [SCBlockFileReaderWriter readBlocklistFromFile: [NSURL fileURLWithPath: pathToBlocklistFile]];
                
                if (readProperties == nil) {
                    NSLog(@"ERROR: Block could not be read from file %@", pathToBlocklistFile);
                    exit(EX_IOERR);
                }
                
                blocklist = readProperties[@"Blocklist"];
                blockAsWhitelist = [readProperties[@"BlockAsWhitelist"] boolValue];
            } else {
                // if the command-line had nothing from us, we'll try to pull them from defaults
                blocklist = defaultsDict[@"Blocklist"];
                blockAsWhitelist = [defaultsDict[@"BlockAsWhitelist"] boolValue];
                
                NSTimeInterval blockDurationSecs = MAX([defaultsDict[@"BlockDuration"] intValue] * 60, 0);
                blockEndDate = [NSDate dateWithTimeIntervalSinceNow: blockDurationSecs];
            }
            
            // read in the other block settings, starting with defaults
            NSDictionary* blockSettingsFromDefaults = @{
                @"ClearCaches": defaultsDict[@"ClearCaches"],
                @"AllowLocalNetworks": defaultsDict[@"AllowLocalNetworks"],
                @"EvaluateCommonSubdomains": defaultsDict[@"EvaluateCommonSubdomains"],
                @"IncludeLinkedDomains": defaultsDict[@"IncludeLinkedDomains"],
                @"BlockSoundShouldPlay": defaultsDict[@"BlockSoundShouldPlay"],
                @"BlockSound": defaultsDict[@"BlockSound"],
                @"EnableErrorReporting": defaultsDict[@"EnableErrorReporting"]
            };
            blockSettings = [blockSettingsFromDefaults mutableCopy];

            // but if settings were passed in command line args, those take top priority
            NSString* argSettingsString = [arguments firstObjectForSignature: blockSettingsSig];
            if (argSettingsString != nil) {
                NSError* jsonParseErr = nil;
                NSDictionary* jsonSettings = [NSJSONSerialization JSONObjectWithData: [argSettingsString dataUsingEncoding: NSUTF8StringEncoding]
                                                                         options: 0
                                                                           error: &jsonParseErr];
                if (jsonSettings == nil) {
                    NSLog(@"ERROR: Failed to parse JSON settings string with error %@", jsonParseErr.localizedDescription);
                    exit(EX_USAGE);
                }
                
                for (NSString* key in blockSettingsFromDefaults) {
                    if (jsonSettings[key] != nil) {
                        blockSettings[key] = jsonSettings[key];
                    }
                }
            }

            if(([blocklist count] == 0 && !blockAsWhitelist) || [blockEndDate timeIntervalSinceNow] < 1) {
                // ya can't start a block without a blocklist, and it can't run for less than a second
                // because that's silly
                NSLog(@"ERROR: Blocklist is empty, or block does not end in the future (%@, %@).", blocklist, blockEndDate);
                exit(EX_CONFIG);
            }

			// We should try to delete the old helper tool if it exists, to avoid confusion
            NSFileManager* fileManager = [NSFileManager defaultManager];
			if([fileManager fileExistsAtPath: @"/Library/PrivilegedHelperTools/org.eyebeam.SelfControl"]) {
				if(![fileManager removeItemAtPath: @"/Library/PrivilegedHelperTools/org.eyebeam.SelfControl" error: nil]) {
					NSLog(@"WARNING: Could not delete old helper binary.");
				}
			}
            
            SCXPCClient* xpc = [SCXPCClient new];

            // use a semaphore to make sure the command-line tool doesn't exit
            // while our blocks are still running
            dispatch_semaphore_t installingBlockSema = dispatch_semaphore_create(0);

            [xpc installDaemon:^(NSError * _Nonnull error) {
                if (error != nil) {
                    NSLog(@"ERROR: Failed to install daemon with error %@", error);
                    exit(EX_SOFTWARE);
                    return;
                } else {
                    // ok, the new helper tool is installed! refresh the connection, then it's time to start the block
                    [xpc refreshConnectionAndRun:^{
                        NSLog(@"Refreshed connection and ready to start block!");
                        [xpc startBlockWithControllingUID: controllingUID
                                                     blocklist: blocklist
                                                   isAllowlist: blockAsWhitelist
                                                       endDate: blockEndDate
                                                 blockSettings: blockSettings
                                                         reply:^(NSError * _Nonnull error) {
                            if (error != nil) {
                                NSLog(@"ERROR: Daemon failed to start block with error %@", error);
                                exit(EX_SOFTWARE);
                                return;
                            }

                            NSLog(@"INFO: Block successfully added.");
                            dispatch_semaphore_signal(installingBlockSema);
                        }];
                    }];
                }
            }];
            
            // obj-c could decide to run our things on the main thread, or not, so be careful
            // but don't let us continue until the block has executed
            if (![NSThread isMainThread]) {
                dispatch_semaphore_wait(installingBlockSema, DISPATCH_TIME_FOREVER);
            } else {
                while (dispatch_semaphore_wait(installingBlockSema, DISPATCH_TIME_NOW)) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate: [NSDate date]];
                }
            }
        } else if([arguments booleanValueForSignature: removeSig]) {
            [SCSentry addBreadcrumb: @"CLI method --remove called" category: @"cli"];
			// So you think you can rid yourself of SelfControl just like that?
			NSLog(@"INFO: Nice try.");
            exit(EX_UNAVAILABLE);
        } else if ([arguments booleanValueForSignature: printSettingsSig]) {
            [SCSentry addBreadcrumb: @"CLI method --print-settings called" category: @"cli"];
            NSLog(@" - Printing SelfControl secured settings for debug: - ");
            NSLog(@"%@", [settings dictionaryRepresentation]);
        } else if ([arguments booleanValueForSignature: isRunningSig]) {
            [SCSentry addBreadcrumb: @"CLI method --is-running called" category: @"cli"];
            BOOL blockIsRunning = [SCBlockUtilities anyBlockIsRunning];
            NSLog(@"%@", blockIsRunning ? @"YES" : @"NO");
        } else if ([arguments booleanValueForSignature: versionSig]) {
            [SCSentry addBreadcrumb: @"CLI method --version called" category: @"cli"];
            NSLog(SELFCONTROL_VERSION_STRING);
        } else {
            // help / usage message
            printf("SelfControl CLI Tool v%s\n", [SELFCONTROL_VERSION_STRING UTF8String]);
            printf("Usage: selfcontrol-cli [--uid <controlling user ID>] <command> [<args>]\n\n");
            printf("Valid commands:\n");
            printf("\n    start --> starts a SelfControl block\n");
            printf("        --blocklist <path to saved blocklist file>\n");
            printf("        --enddate <specified end date for block in ISO8601 format>\n");
            printf("        --settings <other block settings in JSON format>\n");
            printf("\n    is-running --> prints YES if a SelfControl block is currently running, or NO otherwise\n");
            printf("\n    print-settings --> prints the SelfControl settings being used for the active block (for debug purposes)\n");
            printf("\n    version --> prints the version of the SelfControl CLI tool\n");
            printf("\n    schedule --> list, add, remove, enable or disable recurring scheduled blocks\n");
            printf("        (run `selfcontrol-cli schedule help` for details)\n");
            printf("\n");
            printf("--uid argument MUST be specified and set to the controlling user ID if selfcontrol-cli is being run as root. Otherwise, it does not need to be set.\n\n");
            printf("Example start command: selfcontrol-cli start --blocklist /path/to/blocklist.selfcontrol --enddate 2021-02-12T06:53:00Z\n");
        }

        // final sync before we exit
        exit(EXIT_SUCCESS);
	}
}
