//
//  SCXPCAuthorization.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/4/21.
//

#import "SCXPCAuthorization.h"

@implementation SCXPCAuthorization

// all of these methods (basically this whole file) copied from Apple's Even Better Authorization Sample code

static NSString * kCommandKeyAuthRightName    = @"authRightName";
static NSString * kCommandKeyAuthRightDefault = @"authRightDefault";
static NSString * kCommandKeyAuthRightDesc    = @"authRightDescription";

static NSDictionary* kAuthorizationRuleAuthenticateAsAdmin2MinTimeout;

// copied from Apple's Even Better Authorization Sample code
+ (NSError *)checkAuthorization:(NSData *)authData command:(SEL)command
    // Check that the client denoted by authData is allowed to run the specified command.
    // authData is expected to be an NSData with an AuthorizationExternalForm embedded inside.
{
    return [self checkAuthorization: authData rightName: [SCXPCAuthorization authorizationRightForCommand: command]];
}

+ (NSError *)checkAuthorization:(NSData *)authData rightName:(NSString *)rightName
{
    AuthorizationRef            authRef;

    if (rightName == nil) {
        return [NSError errorWithDomain: NSOSStatusErrorDomain code: errAuthorizationInvalidSet userInfo: nil];
    }
    
    authRef = NULL;

    // First check that authData looks reasonable.
    if ( (authData == nil) || ([authData length] != sizeof(AuthorizationExternalForm)) ) {
        return [NSError errorWithDomain:NSOSStatusErrorDomain code:paramErr userInfo:nil];
    }
    
    // Create an authorization ref from that the external form data contained within.
    OSStatus extFormStatus = AuthorizationCreateFromExternalForm([authData bytes], &authRef);
    if (extFormStatus != errAuthorizationSuccess) {
        return [NSError errorWithDomain: NSOSStatusErrorDomain code: extFormStatus userInfo: nil];
    }

    // Authorize the right associated with the command.

    AuthorizationItem   oneRight = { NULL, 0, NULL, 0 };
    AuthorizationRights rights   = { 1, &oneRight };
    AuthorizationFlags flags = kAuthorizationFlagDefaults | kAuthorizationFlagExtendRights | kAuthorizationFlagInteractionAllowed;

    oneRight.name = [rightName UTF8String];
    
    OSStatus authStatus = AuthorizationCopyRights(
        authRef,
        &rights,
        kAuthorizationEmptyEnvironment,
        flags,
        NULL
    );
    if (authRef != NULL) {
        AuthorizationFree(authRef, 0);
    }

    if (authStatus != errAuthorizationSuccess) {
        return [NSError errorWithDomain: NSOSStatusErrorDomain code: authStatus userInfo: nil];
    }

    return nil;
}


+ (NSDictionary *)commandInfo
{
    static dispatch_once_t sOnceToken;
    static NSDictionary *  sCommandInfo;
    
    // static var needs to bre defined before first use
    if (kAuthorizationRuleAuthenticateAsAdmin2MinTimeout == nil) {
        kAuthorizationRuleAuthenticateAsAdmin2MinTimeout = @{
            @"class": @"user",
            @"group": @"admin",
            @"timeout": @(120), // 2 minutes
            @"shared": @(YES),
            @"version": @1, // not entirely sure what this does TBH
            // Enable Touch ID and other biometric authentication on macOS 10.12.2+
            // The authenticate mechanism supports Touch ID when available
            @"mechanisms": @[@"builtin:authenticate"]
        };
    }
    
    dispatch_once(&sOnceToken, ^{
        #pragma clang diagnostic ignored "-Wundeclared-selector"
        
        
        NSDictionary* startBlockCommandInfo = @{
            kCommandKeyAuthRightName    : @"org.eyebeam.SelfControl.startBlock",
            kCommandKeyAuthRightDefault : kAuthorizationRuleAuthenticateAsAdmin2MinTimeout,
            kCommandKeyAuthRightDesc    : NSLocalizedString(
                @"SelfControl needs your username and password to start the block.",
                @"prompt shown when user is required to authorize to start block"
            )
        };
        NSDictionary* modifyBlockCommandInfo = @{
            kCommandKeyAuthRightName    : @"org.eyebeam.SelfControl.modifyBlock",
            kCommandKeyAuthRightDefault : kAuthorizationRuleAuthenticateAsAdmin2MinTimeout,
            kCommandKeyAuthRightDesc    : NSLocalizedString(
                @"SelfControl needs your username and password to modify the block",
                @"prompt shown when user is required to authorize to modify their block"
            )
        };
        
        NSDictionary* updateSchedulesCommandInfo = @{
            kCommandKeyAuthRightName    : @"org.eyebeam.SelfControl.updateSchedules",
            kCommandKeyAuthRightDefault : kAuthorizationRuleAuthenticateAsAdmin2MinTimeout,
            kCommandKeyAuthRightDesc    : NSLocalizedString(
                @"SelfControl needs your username and password to change your block schedules.",
                @"prompt shown when user is required to authorize to change block schedules"
            )
        };

        sCommandInfo = @{
            NSStringFromSelector(@selector(startBlockWithControllingUID:blocklist:isAllowlist:endDate:blockSettings:authorization:reply:)) : startBlockCommandInfo,
            NSStringFromSelector(@selector(updateBlocklist:authorization:reply:)) : modifyBlockCommandInfo,
            NSStringFromSelector(@selector(updateBlockEndDate:authorization:reply:)) : modifyBlockCommandInfo,
            NSStringFromSelector(@selector(updateSchedules:passwordlessOnly:authorization:reply:)) : updateSchedulesCommandInfo
            #pragma clang diagnostic pop
        };
    });
    return sCommandInfo;
}

// fork: rights for actions that only make blocking stricter and are short (see SCPasswordlessMaxMinutes).
// The daemon picks these instead of the admin rights above when a request qualifies. They default to
// "allow" so agents and scripts can start focus blocks without a password; to require the password again:
//   sudo security authorizationdb write org.eyebeam.SelfControl.startShortBlock authenticate-admin
NSString* const SCAuthRightStartShortBlock = @"org.eyebeam.SelfControl.startShortBlock";
NSString* const SCAuthRightTightenShortBlock = @"org.eyebeam.SelfControl.tightenShortBlock";
NSString* const SCAuthRightTightenSchedules = @"org.eyebeam.SelfControl.tightenSchedules";

+ (NSArray<NSDictionary*>*)passwordlessRightInfo {
    NSDictionary* allowRule = @{ @"class": @"allow", @"version": @1 };
    return @[
        @{ kCommandKeyAuthRightName: SCAuthRightStartShortBlock, kCommandKeyAuthRightDefault: allowRule,
           kCommandKeyAuthRightDesc: @"SelfControl wants to start a short block." },
        @{ kCommandKeyAuthRightName: SCAuthRightTightenShortBlock, kCommandKeyAuthRightDefault: allowRule,
           kCommandKeyAuthRightDesc: @"SelfControl wants to extend or add sites to a short block." },
        @{ kCommandKeyAuthRightName: SCAuthRightTightenSchedules, kCommandKeyAuthRightDefault: allowRule,
           kCommandKeyAuthRightDesc: @"SelfControl wants to add to your block schedules." },
    ];
}

+ (void)enumerateRightsUsingBlock:(void (^)(NSString * authRightName, id authRightDefault, NSString * authRightDesc))block
    // Calls the supplied block with information about each known authorization right..
{
    for (NSDictionary* info in [self passwordlessRightInfo]) {
        block(info[kCommandKeyAuthRightName], info[kCommandKeyAuthRightDefault], info[kCommandKeyAuthRightDesc]);
    }
    [self.commandInfo enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        #pragma unused(key)
        #pragma unused(stop)
        NSDictionary *  commandDict;
        NSString *      authRightName;
        id              authRightDefault;
        NSString *      authRightDesc;
        
        // If any of the following asserts fire it's likely that you've got a bug
        // in sCommandInfo.
        
        commandDict = (NSDictionary *) obj;
        assert([commandDict isKindOfClass:[NSDictionary class]]);

        authRightName = [commandDict objectForKey:kCommandKeyAuthRightName];
        assert([authRightName isKindOfClass:[NSString class]]);

        authRightDefault = [commandDict objectForKey:kCommandKeyAuthRightDefault];
        assert(authRightDefault != nil);

        authRightDesc = [commandDict objectForKey:kCommandKeyAuthRightDesc];
        assert([authRightDesc isKindOfClass:[NSString class]]);

        block(authRightName, authRightDefault, authRightDesc);
    }];
}

+ (void)setupAuthorizationRights:(AuthorizationRef)authRef
    // See comment in header.
{
    assert(authRef != NULL);
    [SCXPCAuthorization enumerateRightsUsingBlock:^(NSString * authRightName, id authRightDefault, NSString * authRightDesc) {
        OSStatus    blockErr;
        
        // First get the right.  If we get back errAuthorizationDenied that means there's
        // no current definition, so we add our default one.
        
        blockErr = AuthorizationRightGet([authRightName UTF8String], NULL);
        if (blockErr == errAuthorizationDenied) {
            NSLog(@"setting auth right default for %@: %@", authRightName, authRightDefault);
            blockErr = AuthorizationRightSet(
                authRef,                                    // authRef
                [authRightName UTF8String],                 // rightName
                (__bridge CFTypeRef) authRightDefault,      // rightDefinition
                (__bridge CFStringRef) authRightDesc,       // descriptionKey
                NULL,                                       // bundle (NULL implies main bundle)
                CFSTR("SCXPCAuthorization")                             // localeTableName
            );
            if (blockErr != errAuthorizationSuccess) {
                NSLog(@"WARNING: couldn't add auth right %@ (error %d)", authRightName, (int)blockErr);
            }
        } else {
            // A right already exists (err == noErr) or any other error occurs, we
            // assume that it has been set up in advance by the system administrator or
            // this is the second time we've run.  Either way, there's nothing more for
            // us to do.
        }
    }];
}

+ (NSString *)authorizationRightForCommand:(SEL)command
    // See comment in header.
{
    return [self commandInfo][NSStringFromSelector(command)][kCommandKeyAuthRightName];
}


@end
