//
//  SCAppXPC.h
//  SelfControl
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCXPCClient : NSObject

@property (readonly, getter=isConnected) BOOL connected;

- (void)connectToHelperTool;
- (void)installDaemon:(void(^)(NSError*))callback;
- (void)refreshConnectionAndRun:(void(^)(void))callback;
- (void)connectAndExecuteCommandBlock:(void(^)(NSError *))commandBlock;

- (void)getVersion:(void(^)(NSString* version, NSError* error))reply;
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply;
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist reply:(void(^)(NSError* error))reply;
- (void)updateBlockEndDate:(NSDate*)newEndDate reply:(void(^)(NSError* error))reply;

// fork: connects to the daemon if it's running and matches this build's version,
// otherwise (re)installs it, which asks for an admin password. Callback may run on any thread.
- (void)ensureDaemonInstalled:(void(^)(NSError* _Nullable error))callback;

// fork: replace the recurring block schedules. The daemon must already be installed
// (call installDaemon first: it may have unloaded itself if no block or schedule was active).
- (void)updateSchedules:(NSArray<NSDictionary*>*)schedules reply:(void(^)(NSError* error))reply;
// passwordlessOnly: fail (SCScheduleErrorDomain code 32) instead of asking for the admin password
- (void)updateSchedules:(NSArray<NSDictionary*>*)schedules passwordlessOnly:(BOOL)passwordlessOnly reply:(void(^)(NSError* error))reply;

@end

NS_ASSUME_NONNULL_END
