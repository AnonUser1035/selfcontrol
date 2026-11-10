//
//  ScheduleWindowController.h
//  SelfControl
//
//  fork: window for managing recurring scheduled blocks (see SCScheduleUtilities.h).
//  Built in code rather than a xib so it's easy to review and modify.
//

#import <Cocoa/Cocoa.h>

@class SCXPCClient;

NS_ASSUME_NONNULL_BEGIN

@interface ScheduleWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithXPCClient:(SCXPCClient*)xpc;

// re-read schedules from the secured settings and redraw
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
