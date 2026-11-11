//
//  SCDaemonXPC.m
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import "SCDaemonXPC.h"
#import "SCDaemonBlockMethods.h"
#import "SCXPCAuthorization.h"
#import "SCScheduleUtilities.h"

// fork: requests that only make blocking stricter and last at most this long can use the passwordless rights
static NSTimeInterval SCPasswordlessMaxSeconds(void) { return SCPasswordlessMaxMinutes * 60 + 60; /* a minute of slack for clock skew */ }

@implementation SCDaemonXPC

- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: startBlockWithControllingUID");

    // allowlist blocks cut off nearly everything, so they always need the password
    BOOL passwordless = !isAllowlist && [endDate timeIntervalSinceNow] <= SCPasswordlessMaxSeconds();
    NSString* right = passwordless ? SCAuthRightStartShortBlock : [SCXPCAuthorization authorizationRightForCommand: _cmd];
    NSError* error = [SCXPCAuthorization checkAuthorization: authData rightName: right];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"AUTHORIZATION ACCEPTED for startBlock with authData %@ and command %s", authData, sel_getName(_cmd));
    }

    [SCDaemonBlockMethods startBlockWithControllingUID: controllingUID blocklist: blocklist isAllowlist:isAllowlist endDate: endDate blockSettings:blockSettings authorization: authData reply: reply];
}

- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateBlocklist");

    NSDate* currentEndDate = [[SCSettings sharedSettings] valueForKey: @"BlockEndDate"];
    BOOL passwordless = [currentEndDate isKindOfClass: [NSDate class]] && [currentEndDate timeIntervalSinceNow] <= SCPasswordlessMaxSeconds();
    NSString* right = passwordless ? SCAuthRightTightenShortBlock : [SCXPCAuthorization authorizationRightForCommand: _cmd];
    NSError* error = [SCXPCAuthorization checkAuthorization: authData rightName: right];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"AUTHORIZATION ACCEPTED for updateBlocklist with authData %@ and command %s", authData, sel_getName(_cmd));
    }
    
    [SCDaemonBlockMethods updateBlocklist: newBlocklist authorization: authData reply: reply];
}

- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateBlockEndDate");

    BOOL passwordless = [newEndDate timeIntervalSinceNow] <= SCPasswordlessMaxSeconds();
    NSString* right = passwordless ? SCAuthRightTightenShortBlock : [SCXPCAuthorization authorizationRightForCommand: _cmd];
    NSError* error = [SCXPCAuthorization checkAuthorization: authData rightName: right];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"AUTHORIZATION ACCEPTED for updateBlockENdDate with authData %@ and command %s", authData, sel_getName(_cmd));
    }
    
    [SCDaemonBlockMethods updateBlockEndDate: newEndDate authorization: authData reply: reply];
}

- (void)updateSchedules:(NSArray<NSDictionary*>*)schedules passwordlessOnly:(BOOL)passwordlessOnly authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateSchedules");

    NSDate* now = [NSDate date];
    NSArray* newSchedules = [SCScheduleUtilities schedulesByPruningExpired: schedules atDate: now];
    NSString* passwordReason = nil;
    BOOL passwordless = [SCScheduleUtilities changeIsPasswordlessFromSchedules: [[SCSettings sharedSettings] valueForKey: @"Schedules"]
                                                                   toSchedules: newSchedules
                                                                        atDate: now
                                                                        reason: &passwordReason];
    if (!passwordless) {
        NSLog(@"INFO: schedule change needs the admin password because it %@", passwordReason);
        if (passwordlessOnly) {
            reply([NSError errorWithDomain: SCScheduleErrorDomain code: 32 userInfo: @{
                NSLocalizedDescriptionKey: [NSString stringWithFormat: @"This needs your admin password because it %@.", passwordReason]
            }]);
            return;
        }
    }
    NSString* right = passwordless ? SCAuthRightTightenSchedules : [SCXPCAuthorization authorizationRightForCommand: _cmd];
    NSError* error = [SCXPCAuthorization checkAuthorization: authData rightName: right];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
        }
        reply(error);
        return;
    }

    [SCDaemonBlockMethods updateSchedules: newSchedules requirePasswordlessChange: passwordless reply: reply];
}

// Part of the HelperToolProtocol.  Returns the version number of the tool.  Note that never
// requires authorization.
- (void)getVersionWithReply:(void(^)(NSString * version))reply {
    NSLog(@"XPC method called: getVersionWithReply");
    // We specifically don't check for authorization here.  Everyone is always allowed to get
    // the version of the helper tool.
    reply(SELFCONTROL_VERSION_STRING);
}

@end
