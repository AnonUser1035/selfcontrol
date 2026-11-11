//
//  SCXPCAuthorization.h
//  SelfControl
//
//  Created by Charlie Stigler on 1/4/21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const SCAuthRightStartShortBlock;
extern NSString* const SCAuthRightTightenShortBlock;
extern NSString* const SCAuthRightTightenSchedules;

@interface SCXPCAuthorization : NSObject

+ (NSError *)checkAuthorization:(NSData *)authData command:(SEL)command;
// fork: check a specific right (used when the daemon picks a passwordless right for a qualifying request)
+ (NSError *)checkAuthorization:(NSData *)authData rightName:(NSString *)rightName;

+ (NSString *)authorizationRightForCommand:(SEL)command;
    // For a given command selector, return the associated authorization right name.

+ (void)setupAuthorizationRights:(AuthorizationRef)authRef;
    // Set up the default authorization rights in the authorization database.

@end

NS_ASSUME_NONNULL_END
