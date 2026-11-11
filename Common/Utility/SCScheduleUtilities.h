//
//  SCScheduleUtilities.h
//  SelfControl
//
//  Recurring scheduled blocks. Schedules are stored by the daemon in the secured
//  settings (key "Schedules") as an array of plist dictionaries, so they can travel
//  over XPC and be read (but not written) by the app and CLI.
//
//  This file depends only on Foundation so it can be shared by the app, CLI and daemon.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const SCScheduleErrorDomain;

extern NSString* const SCScheduleKeyID;            // NSString, unique (UUID)
extern NSString* const SCScheduleKeyName;          // NSString, optional label
extern NSString* const SCScheduleKeyEnabled;       // NSNumber (BOOL)
extern NSString* const SCScheduleKeyWeekdays;      // NSArray<NSNumber*>, 1 = Sunday ... 7 = Saturday (NSCalendar convention).
                                                   //   These are the days a window *starts* on.
extern NSString* const SCScheduleKeyStartMinute;   // NSNumber, minutes after local midnight, 0-1439
extern NSString* const SCScheduleKeyEndMinute;     // NSNumber, 0-1439. If <= start, the window ends the next day.
extern NSString* const SCScheduleKeyBlocklist;     // NSArray<NSString*>, the schedule's own copy of the sites to block
extern NSString* const SCScheduleKeyBlockSettings; // NSDictionary, same keys the app passes to startBlock (ClearCaches etc.)
extern NSString* const SCScheduleKeyDate;          // NSString "yyyy-MM-dd" (local). If present, this is a one-off schedule:
                                                   //   a single window starting on that date. Weekdays is ignored.
                                                   //   The daemon deletes one-offs once their window has ended.

extern NSUInteger const SCScheduleMaxCount;

// Changes that only make blocking stricter (start a block, extend it, add sites, add or enable a schedule)
// don't need an admin password, as long as the restriction they add lasts at most this long.
// Anything that loosens blocking, or adds a longer restriction, still needs the password.
extern NSInteger const SCPasswordlessMaxMinutes;

@interface SCScheduleUtilities : NSObject

+ (NSMutableDictionary*)scheduleWithName:(nullable NSString*)name
                                weekdays:(NSArray<NSNumber*>*)weekdays
                             startMinute:(NSInteger)startMinute
                               endMinute:(NSInteger)endMinute
                               blocklist:(NSArray<NSString*>*)blocklist
                           blockSettings:(NSDictionary*)blockSettings;

// structural validation (types, ranges, non-empty lists, unique IDs)
+ (nullable NSError*)validateSchedule:(NSDictionary*)schedule;
+ (nullable NSError*)validateSchedules:(NSArray*)schedules;

// enforces "a schedule can't be removed, disabled or weakened while its window is active".
// adding sites to an active schedule is allowed.
+ (nullable NSError*)validateChangeFromSchedules:(nullable NSArray*)oldSchedules
                                     toSchedules:(NSArray*)newSchedules
                                          atDate:(NSDate*)date;

// if an enabled schedule has a window containing `date`, returns that window's end date, else nil
+ (nullable NSDate*)activeWindowEndForSchedule:(NSDictionary*)schedule atDate:(NSDate*)date;
+ (BOOL)scheduleIsActive:(NSDictionary*)schedule atDate:(NSDate*)date;
+ (NSArray<NSDictionary*>*)activeSchedules:(nullable NSArray*)schedules atDate:(NSDate*)date;
// next window start strictly after `date` for an enabled schedule, else nil
+ (nullable NSDate*)nextWindowStartForSchedule:(NSDictionary*)schedule afterDate:(NSDate*)date;
+ (BOOL)anyEnabledSchedules:(nullable NSArray*)schedules;

+ (nullable NSDictionary*)scheduleWithID:(NSString*)scheduleID inSchedules:(nullable NSArray*)schedules;

// one-off schedules
+ (NSMutableDictionary*)oneOffScheduleWithName:(nullable NSString*)name
                                          date:(NSString*)dateString
                                   startMinute:(NSInteger)startMinute
                                     endMinute:(NSInteger)endMinute
                                     blocklist:(NSArray<NSString*>*)blocklist
                                 blockSettings:(NSDictionary*)blockSettings;
+ (BOOL)isOneOffSchedule:(NSDictionary*)schedule;
+ (BOOL)oneOffScheduleIsExpired:(NSDictionary*)schedule atDate:(NSDate*)date;
+ (NSArray<NSDictionary*>*)schedulesByRemovingExpiredOneOffs:(nullable NSArray*)schedules atDate:(NSDate*)date;
+ (NSString*)dateStringForDate:(NSDate*)date;          // local "yyyy-MM-dd"
+ (nullable NSString*)dateStringFromUserString:(NSString*)string atDate:(NSDate*)now; // "today", "tomorrow" or "yyyy-MM-dd"

// length of one window in minutes (handles windows that cross midnight)
+ (NSInteger)windowMinutesForSchedule:(NSDictionary*)schedule;

// YES if going from old to new only makes blocking stricter, and nothing it adds lasts longer than
// SCPasswordlessMaxMinutes. Removing, disabling, retiming or removing sites from a schedule is never passwordless.
+ (BOOL)changeIsPasswordlessFromSchedules:(nullable NSArray*)oldSchedules
                              toSchedules:(NSArray*)newSchedules
                                   atDate:(NSDate*)date
                                   reason:(NSString* _Nullable * _Nullable)reason;

// human-readable descriptions
+ (NSString*)daysDescriptionForSchedule:(NSDictionary*)schedule;  // "Weekdays", "Every day", "Mon, Wed, Fri"
+ (NSString*)timeDescriptionForSchedule:(NSDictionary*)schedule;  // "9:00 AM – 5:00 PM (next day)"
+ (NSString*)timeStringForMinute:(NSInteger)minute;
+ (NSString*)displayNameForSchedule:(NSDictionary*)schedule;      // name, or days + time if unnamed

// parsing helpers for the CLI
+ (nullable NSArray<NSNumber*>*)weekdaysFromString:(NSString*)string;  // "mon-fri", "weekdays", "sat,sun", "daily"
+ (NSInteger)minuteFromTimeString:(NSString*)string;                    // "09:00", "9:30", "21:15", "9pm"; -1 if invalid

@end

NS_ASSUME_NONNULL_END
