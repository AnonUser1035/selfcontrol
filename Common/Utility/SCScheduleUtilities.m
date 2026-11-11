//
//  SCScheduleUtilities.m
//  SelfControl
//

#import "SCScheduleUtilities.h"

NSString* const SCScheduleErrorDomain = @"org.eyebeam.SelfControl.Schedule";

NSString* const SCScheduleKeyID = @"ID";
NSString* const SCScheduleKeyName = @"Name";
NSString* const SCScheduleKeyEnabled = @"Enabled";
NSString* const SCScheduleKeyWeekdays = @"Weekdays";
NSString* const SCScheduleKeyStartMinute = @"StartMinute";
NSString* const SCScheduleKeyEndMinute = @"EndMinute";
NSString* const SCScheduleKeyBlocklist = @"Blocklist";
NSString* const SCScheduleKeyBlockSettings = @"BlockSettings";
NSString* const SCScheduleKeyDate = @"Date";
NSString* const SCScheduleKeySkipDates = @"SkipDates";

NSUInteger const SCScheduleMaxCount = 50;
NSInteger const SCPasswordlessMaxMinutes = 4 * 60;
NSInteger const SCScheduleChangeNoticeMinutes = 12 * 60;
static NSUInteger const kMaxSkipDates = 366;

static NSInteger const kMinutesPerDay = 24 * 60;

@implementation SCScheduleUtilities

#pragma mark - Construction

+ (NSMutableDictionary*)scheduleWithName:(NSString*)name
                                weekdays:(NSArray<NSNumber*>*)weekdays
                             startMinute:(NSInteger)startMinute
                               endMinute:(NSInteger)endMinute
                               blocklist:(NSArray<NSString*>*)blocklist
                           blockSettings:(NSDictionary*)blockSettings {
    NSMutableDictionary* schedule = [@{
        SCScheduleKeyID: [[NSUUID UUID] UUIDString],
        SCScheduleKeyEnabled: @YES,
        SCScheduleKeyWeekdays: [self normalizedWeekdays: weekdays],
        SCScheduleKeyStartMinute: @(startMinute),
        SCScheduleKeyEndMinute: @(endMinute),
        SCScheduleKeyBlocklist: blocklist ?: @[],
        SCScheduleKeyBlockSettings: blockSettings ?: @{}
    } mutableCopy];
    if (name.length > 0) {
        schedule[SCScheduleKeyName] = name;
    }
    return schedule;
}

+ (NSMutableDictionary*)oneOffScheduleWithName:(NSString*)name
                                          date:(NSString*)dateString
                                   startMinute:(NSInteger)startMinute
                                     endMinute:(NSInteger)endMinute
                                     blocklist:(NSArray<NSString*>*)blocklist
                                 blockSettings:(NSDictionary*)blockSettings {
    NSMutableDictionary* schedule = [self scheduleWithName: name weekdays: @[] startMinute: startMinute endMinute: endMinute blocklist: blocklist blockSettings: blockSettings];
    schedule[SCScheduleKeyDate] = dateString;
    return schedule;
}

+ (BOOL)isOneOffSchedule:(NSDictionary*)schedule {
    return [schedule[SCScheduleKeyDate] isKindOfClass: [NSString class]];
}

+ (NSArray<NSNumber*>*)normalizedWeekdays:(NSArray*)weekdays {
    NSMutableSet<NSNumber*>* set = [NSMutableSet set];
    for (id day in weekdays) {
        if ([day isKindOfClass: [NSNumber class]]) [set addObject: @([day integerValue])];
    }
    return [[set allObjects] sortedArrayUsingSelector: @selector(compare:)];
}

#pragma mark - Errors

+ (NSError*)errorWithCode:(NSInteger)code description:(NSString*)description {
    return [NSError errorWithDomain: SCScheduleErrorDomain
                               code: code
                           userInfo: @{ NSLocalizedDescriptionKey: description }];
}

#pragma mark - Validation

+ (NSError*)validateSchedule:(NSDictionary*)schedule {
    if (![schedule isKindOfClass: [NSDictionary class]]) {
        return [self errorWithCode: 1 description: @"Schedule is not a dictionary."];
    }

    id scheduleID = schedule[SCScheduleKeyID];
    if (![scheduleID isKindOfClass: [NSString class]] || [scheduleID length] == 0) {
        return [self errorWithCode: 2 description: @"Schedule is missing an ID."];
    }

    id name = schedule[SCScheduleKeyName];
    if (name != nil && ![name isKindOfClass: [NSString class]]) {
        return [self errorWithCode: 3 description: @"Schedule name must be text."];
    }

    if (![schedule[SCScheduleKeyEnabled] isKindOfClass: [NSNumber class]]) {
        return [self errorWithCode: 4 description: @"Schedule is missing its enabled flag."];
    }

    id dateString = schedule[SCScheduleKeyDate];
    if (dateString != nil && ([self dateComponentsFromDateString: dateString] == nil)) {
        return [self errorWithCode: 12 description: @"One-off schedule has an invalid date."];
    }
    id weekdays = schedule[SCScheduleKeyWeekdays] ?: @[];
    if (![weekdays isKindOfClass: [NSArray class]] || (dateString == nil && [weekdays count] == 0)) {
        return [self errorWithCode: 5 description: @"Pick at least one day for the schedule."];
    }
    for (id day in weekdays) {
        if (![day isKindOfClass: [NSNumber class]] || [day integerValue] < 1 || [day integerValue] > 7) {
            return [self errorWithCode: 6 description: @"Schedule has an invalid day."];
        }
    }

    id start = schedule[SCScheduleKeyStartMinute];
    id end = schedule[SCScheduleKeyEndMinute];
    if (![start isKindOfClass: [NSNumber class]] || ![end isKindOfClass: [NSNumber class]]
        || [start integerValue] < 0 || [start integerValue] >= kMinutesPerDay
        || [end integerValue] < 0 || [end integerValue] >= kMinutesPerDay) {
        return [self errorWithCode: 7 description: @"Schedule has an invalid start or end time."];
    }
    if ([start integerValue] == [end integerValue]) {
        return [self errorWithCode: 8 description: @"A schedule's start and end time can't be the same."];
    }

    id blocklist = schedule[SCScheduleKeyBlocklist];
    if (![blocklist isKindOfClass: [NSArray class]] || [blocklist count] == 0) {
        return [self errorWithCode: 9 description: @"A schedule needs at least one site to block."];
    }
    for (id site in blocklist) {
        if (![site isKindOfClass: [NSString class]] || [site length] == 0) {
            return [self errorWithCode: 10 description: @"Schedule has an invalid site in its blocklist."];
        }
    }

    id blockSettings = schedule[SCScheduleKeyBlockSettings];
    if (blockSettings != nil && ![blockSettings isKindOfClass: [NSDictionary class]]) {
        return [self errorWithCode: 11 description: @"Schedule has invalid block settings."];
    }

    id skipDates = schedule[SCScheduleKeySkipDates];
    if (skipDates != nil) {
        if (![skipDates isKindOfClass: [NSArray class]] || [skipDates count] > kMaxSkipDates) {
            return [self errorWithCode: 13 description: @"Schedule has invalid skipped days."];
        }
        for (id day in skipDates) {
            if ([self dateComponentsFromDateString: day] == nil) {
                return [self errorWithCode: 13 description: @"Schedule has an invalid skipped day."];
            }
        }
    }

    return nil;
}

+ (NSError*)validateSchedules:(NSArray*)schedules {
    if (![schedules isKindOfClass: [NSArray class]]) {
        return [self errorWithCode: 20 description: @"Schedules must be a list."];
    }
    if (schedules.count > SCScheduleMaxCount) {
        return [self errorWithCode: 21 description: [NSString stringWithFormat: @"You can have at most %lu schedules.", (unsigned long)SCScheduleMaxCount]];
    }
    NSMutableSet* seenIDs = [NSMutableSet set];
    for (NSDictionary* schedule in schedules) {
        NSError* err = [self validateSchedule: schedule];
        if (err != nil) return err;
        if ([seenIDs containsObject: schedule[SCScheduleKeyID]]) {
            return [self errorWithCode: 22 description: @"Two schedules have the same ID."];
        }
        [seenIDs addObject: schedule[SCScheduleKeyID]];
    }
    return nil;
}

+ (NSError*)validateChangeFromSchedules:(NSArray*)oldSchedules toSchedules:(NSArray*)newSchedules atDate:(NSDate*)date {
    for (NSDictionary* oldSchedule in oldSchedules) {
        if (![oldSchedule isKindOfClass: [NSDictionary class]]) continue;
        NSDate* windowEnd = [self activeWindowEndForSchedule: oldSchedule atDate: date];
        if (windowEnd == nil) continue; // not active, free to change

        NSDictionary* newSchedule = [self scheduleWithID: oldSchedule[SCScheduleKeyID] inSchedules: newSchedules];
        BOOL weakened = (newSchedule == nil)
            || ![newSchedule[SCScheduleKeyEnabled] boolValue]
            || ![[NSSet setWithArray: [self normalizedWeekdays: newSchedule[SCScheduleKeyWeekdays]]] isEqualToSet: [NSSet setWithArray: [self normalizedWeekdays: oldSchedule[SCScheduleKeyWeekdays]]]]
            || !((newSchedule[SCScheduleKeyDate] == nil && oldSchedule[SCScheduleKeyDate] == nil) || [newSchedule[SCScheduleKeyDate] isEqual: oldSchedule[SCScheduleKeyDate]])
            || [newSchedule[SCScheduleKeyStartMinute] integerValue] != [oldSchedule[SCScheduleKeyStartMinute] integerValue]
            || [newSchedule[SCScheduleKeyEndMinute] integerValue] != [oldSchedule[SCScheduleKeyEndMinute] integerValue]
            || ![[NSSet setWithArray: oldSchedule[SCScheduleKeyBlocklist] ?: @[]] isSubsetOfSet: [NSSet setWithArray: newSchedule[SCScheduleKeyBlocklist] ?: @[]]]
            || [self activeWindowEndForSchedule: newSchedule atDate: date] == nil; // e.g. today's window was skipped

        if (weakened) {
            NSDateFormatter* formatter = [NSDateFormatter new];
            formatter.dateStyle = NSDateFormatterNoStyle;
            formatter.timeStyle = NSDateFormatterShortStyle;
            formatter.doesRelativeDateFormatting = YES;
            NSString* description = [NSString stringWithFormat: @"\"%@\" is active right now. You can only add sites to it until it ends at %@.",
                                     [self displayNameForSchedule: oldSchedule], [formatter stringFromDate: windowEnd]];
            return [self errorWithCode: 30 description: description];
        }
    }
    return nil;
}

#pragma mark - Time math

+ (NSCalendar*)calendar {
    // pick up time zone changes (e.g. travel) even in a long-running daemon
    [NSTimeZone resetSystemTimeZone];
    NSCalendar* cal = [[NSCalendar alloc] initWithCalendarIdentifier: NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone systemTimeZone];
    return cal;
}

// wall-clock time `minute` on the day containing `day`, offset by `dayOffset` days.
// going through components keeps this correct across DST changes.
+ (NSDate*)dateOnDay:(NSDate*)day dayOffset:(NSInteger)dayOffset minute:(NSInteger)minute calendar:(NSCalendar*)cal {
    NSDateComponents* comps = [cal components: NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate: day];
    comps.day += dayOffset;
    comps.hour = minute / 60;
    comps.minute = minute % 60;
    comps.second = 0;
    return [cal dateFromComponents: comps];
}

// "yyyy-MM-dd" -> year/month/day components, or nil if malformed / not a real date
+ (NSDateComponents*)dateComponentsFromDateString:(id)string {
    if (![string isKindOfClass: [NSString class]]) return nil;
    NSArray<NSString*>* parts = [string componentsSeparatedByString: @"-"];
    if (parts.count != 3 || parts[0].length != 4 || parts[1].length != 2 || parts[2].length != 2) return nil;
    NSCharacterSet* nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString* part in parts) {
        if ([part rangeOfCharacterFromSet: nonDigits].location != NSNotFound) return nil;
    }
    NSDateComponents* comps = [NSDateComponents new];
    comps.year = parts[0].integerValue;
    comps.month = parts[1].integerValue;
    comps.day = parts[2].integerValue;
    if (comps.month < 1 || comps.month > 12 || comps.day < 1 || comps.day > 31) return nil;
    // reject dates like 2026-02-31 that would silently roll over
    NSCalendar* cal = [self calendar];
    NSDate* date = [cal dateFromComponents: comps];
    if (date == nil || [cal component: NSCalendarUnitDay fromDate: date] != comps.day) return nil;
    return comps;
}

+ (NSString*)dateStringForDate:(NSDate*)date {
    NSDateComponents* comps = [[self calendar] components: NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate: date];
    return [NSString stringWithFormat: @"%04ld-%02ld-%02ld", (long)comps.year, (long)comps.month, (long)comps.day];
}

+ (NSString*)dateStringFromUserString:(NSString*)string atDate:(NSDate*)now {
    NSString* str = [[string lowercaseString] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
    NSCalendar* cal = [self calendar];
    if ([str isEqualToString: @"today"]) return [self dateStringForDate: now];
    if ([str isEqualToString: @"tomorrow"]) return [self dateStringForDate: [cal dateByAddingUnit: NSCalendarUnitDay value: 1 toDate: now options: 0]];
    if ([self dateComponentsFromDateString: str] != nil) return str;
    // a weekday name: the next such day, today included
    NSInteger weekday = [self weekdayFromToken: [str hasPrefix: @"next"] ? [[str substringFromIndex: 4] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] : str];
    if (weekday == 0) return nil;
    NSInteger todayWeekday = [cal component: NSCalendarUnitWeekday fromDate: now];
    NSInteger offset = (weekday - todayWeekday + 7) % 7;
    if (offset == 0 && [str hasPrefix: @"next"]) offset = 7;
    return [self dateStringForDate: [self dateOnDay: now dayOffset: offset minute: 12 * 60 calendar: cal]];
}

+ (NSDate*)dateForDateString:(NSString*)string {
    NSDateComponents* comps = [self dateComponentsFromDateString: string];
    return comps != nil ? [[self calendar] dateFromComponents: comps] : nil;
}

// start and end of a one-off schedule's single window
+ (BOOL)oneOffWindowForSchedule:(NSDictionary*)schedule start:(NSDate**)start end:(NSDate**)end {
    NSDateComponents* day = [self dateComponentsFromDateString: schedule[SCScheduleKeyDate]];
    NSInteger startMinute = [schedule[SCScheduleKeyStartMinute] integerValue];
    NSInteger endMinute = [schedule[SCScheduleKeyEndMinute] integerValue];
    if (day == nil || startMinute == endMinute) return NO;
    NSCalendar* cal = [self calendar];
    NSDate* dayDate = [cal dateFromComponents: day];
    *start = [self dateOnDay: dayDate dayOffset: 0 minute: startMinute calendar: cal];
    *end = [self dateOnDay: dayDate dayOffset: (endMinute <= startMinute ? 1 : 0) minute: endMinute calendar: cal];
    return YES;
}

+ (BOOL)oneOffScheduleIsExpired:(NSDictionary*)schedule atDate:(NSDate*)date {
    NSDate *start, *end;
    if (![self isOneOffSchedule: schedule] || ![self oneOffWindowForSchedule: schedule start: &start end: &end]) return NO;
    return [end compare: date] != NSOrderedDescending;
}

+ (NSArray<NSDictionary*>*)schedulesByRemovingExpiredOneOffs:(NSArray*)schedules atDate:(NSDate*)date {
    NSMutableArray* kept = [NSMutableArray array];
    for (NSDictionary* schedule in schedules) {
        if (![schedule isKindOfClass: [NSDictionary class]] || ![self oneOffScheduleIsExpired: schedule atDate: date]) {
            [kept addObject: schedule];
        }
    }
    return kept;
}

+ (NSArray<NSDictionary*>*)schedulesByPruningExpired:(NSArray*)schedules atDate:(NSDate*)date {
    // a skipped window is over once its day is two days back (windows are shorter than a day)
    NSCalendar* cal = [self calendar];
    NSString* cutoff = [self dateStringForDate: [cal dateByAddingUnit: NSCalendarUnitDay value: -2 toDate: date options: 0]];
    NSMutableArray* kept = [NSMutableArray array];
    for (NSDictionary* schedule in [self schedulesByRemovingExpiredOneOffs: schedules atDate: date]) {
        NSArray* skipDates = [schedule isKindOfClass: [NSDictionary class]] ? schedule[SCScheduleKeySkipDates] : nil;
        if (![skipDates isKindOfClass: [NSArray class]]) {
            [kept addObject: schedule];
            continue;
        }
        NSMutableArray* fresh = [NSMutableArray array];
        for (id day in skipDates) {
            if (![day isKindOfClass: [NSString class]] || [(NSString*)day compare: cutoff] == NSOrderedDescending) [fresh addObject: day];
        }
        if (fresh.count == skipDates.count) {
            [kept addObject: schedule];
        } else {
            NSMutableDictionary* pruned = [schedule mutableCopy];
            if (fresh.count > 0) pruned[SCScheduleKeySkipDates] = fresh;
            else [pruned removeObjectForKey: SCScheduleKeySkipDates];
            [kept addObject: pruned];
        }
    }
    return kept;
}

+ (NSArray<NSString*>*)skipDatesForSchedule:(NSDictionary*)schedule {
    NSArray* skipDates = schedule[SCScheduleKeySkipDates];
    if (![skipDates isKindOfClass: [NSArray class]] || [self isOneOffSchedule: schedule]) return @[];
    NSMutableSet* set = [NSMutableSet set];
    for (id day in skipDates) {
        if ([day isKindOfClass: [NSString class]]) [set addObject: day];
    }
    return [[set allObjects] sortedArrayUsingSelector: @selector(compare:)];
}

+ (BOOL)schedule:(NSDictionary*)schedule hasWindowOnDateString:(NSString*)dateString {
    if ([self isOneOffSchedule: schedule]) return [schedule[SCScheduleKeyDate] isEqual: dateString];
    NSDate* day = [self dateForDateString: dateString];
    if (day == nil) return NO;
    NSInteger weekday = [[self calendar] component: NSCalendarUnitWeekday fromDate: day];
    return [[self normalizedWeekdays: schedule[SCScheduleKeyWeekdays]] containsObject: @(weekday)];
}

+ (NSInteger)windowMinutesForSchedule:(NSDictionary*)schedule {
    NSInteger start = [schedule[SCScheduleKeyStartMinute] integerValue];
    NSInteger end = [schedule[SCScheduleKeyEndMinute] integerValue];
    return ((end - start) % kMinutesPerDay + kMinutesPerDay) % kMinutesPerDay;
}

// pieces of `windows` not covered by any window in `cover`
static NSArray<NSArray<NSDate*>*>* SCSubtractWindows(NSArray<NSArray<NSDate*>*>* windows, NSArray<NSArray<NSDate*>*>* cover) {
    NSMutableArray* result = [NSMutableArray array];
    for (NSArray<NSDate*>* window in windows) {
        NSArray<NSArray<NSDate*>*>* pieces = @[window];
        for (NSArray<NSDate*>* c in cover) {
            NSMutableArray* next = [NSMutableArray array];
            for (NSArray<NSDate*>* piece in pieces) {
                if ([c[1] compare: piece[0]] != NSOrderedDescending || [c[0] compare: piece[1]] != NSOrderedAscending) {
                    [next addObject: piece]; // no overlap
                    continue;
                }
                if ([c[0] compare: piece[0]] == NSOrderedDescending) [next addObject: @[piece[0], c[0]]];
                if ([c[1] compare: piece[1]] == NSOrderedAscending) [next addObject: @[c[1], piece[1]]];
            }
            pieces = next;
        }
        [result addObjectsFromArray: pieces];
    }
    return result;
}

// earliest moment of `windows` within [from, to), ignoring slivers under a second; nil if none
static NSDate* SCFirstMomentInWindows(NSArray<NSArray<NSDate*>*>* windows, NSDate* from, NSDate* to) {
    NSDate* first = nil;
    for (NSArray<NSDate*>* window in windows) {
        NSDate* start = [window[0] laterDate: from];
        NSDate* end = [window[1] earlierDate: to];
        if ([end timeIntervalSinceDate: start] < 1) continue;
        if (first == nil || [start compare: first] == NSOrderedAscending) first = start;
    }
    return first;
}

// far enough ahead that comparing two schedules' windows up to here covers every difference between them:
// past their last specific date (one-off date or skip date), recurring windows just repeat weekly
+ (NSDate*)comparisonHorizonForSchedules:(NSArray<NSDictionary*>*)schedules atDate:(NSDate*)date {
    NSDate* latest = date;
    for (NSDictionary* schedule in schedules) {
        NSMutableArray* days = [[self skipDatesForSchedule: schedule] mutableCopy];
        if ([self isOneOffSchedule: schedule]) [days addObject: schedule[SCScheduleKeyDate]];
        for (NSString* day in days) {
            NSDate* d = [self dateForDateString: day];
            if (d != nil) latest = [latest laterDate: d];
        }
    }
    return [[self calendar] dateByAddingUnit: NSCalendarUnitDay value: 9 toDate: latest options: 0];
}

+ (BOOL)changeIsPasswordlessFromSchedules:(NSArray*)oldSchedules toSchedules:(NSArray*)newSchedules atDate:(NSDate*)date reason:(NSString**)reason {
    NSString* why = nil;
    NSDate* noticeEnd = [date dateByAddingTimeInterval: SCScheduleChangeNoticeMinutes * 60];

    NSMutableOrderedSet<NSString*>* ids = [NSMutableOrderedSet orderedSet];
    for (NSArray* list in @[oldSchedules ?: @[], newSchedules ?: @[]]) {
        for (NSDictionary* schedule in list) {
            if ([schedule isKindOfClass: [NSDictionary class]] && [schedule[SCScheduleKeyID] isKindOfClass: [NSString class]]) {
                [ids addObject: schedule[SCScheduleKeyID]];
            }
        }
    }

    for (NSString* scheduleID in ids) {
        // only enabled, unfinished schedules restrict anything
        NSDictionary* oldSchedule = [self scheduleWithID: scheduleID inSchedules: oldSchedules];
        NSDictionary* newSchedule = [self scheduleWithID: scheduleID inSchedules: newSchedules];
        if (oldSchedule != nil && (![oldSchedule[SCScheduleKeyEnabled] boolValue] || [self oneOffScheduleIsExpired: oldSchedule atDate: date])) oldSchedule = nil;
        if (newSchedule != nil && ![newSchedule[SCScheduleKeyEnabled] boolValue]) newSchedule = nil;
        if (oldSchedule == nil && newSchedule == nil) continue;

        NSSet* oldSites = [NSSet setWithArray: oldSchedule[SCScheduleKeyBlocklist] ?: @[]];
        NSSet* newSites = [NSSet setWithArray: newSchedule[SCScheduleKeyBlocklist] ?: @[]];
        BOOL bothExist = oldSchedule != nil && newSchedule != nil;
        BOOL settingsChanged = bothExist
            && !((newSchedule[SCScheduleKeyBlockSettings] == nil && oldSchedule[SCScheduleKeyBlockSettings] == nil)
                 || [newSchedule[SCScheduleKeyBlockSettings] isEqual: oldSchedule[SCScheduleKeyBlockSettings]]);
        BOOL sitesRemoved = bothExist && ![oldSites isSubsetOfSet: newSites];
        BOOL sitesAdded = bothExist && ![newSites isSubsetOfSet: oldSites];

        // loosening: whatever restriction goes away must be at least the notice period out
        if (oldSchedule != nil) {
            NSArray* lost = [self windowsForSchedule: oldSchedule overlappingFrom: date to: noticeEnd];
            if (newSchedule != nil && !sitesRemoved && !settingsChanged) {
                lost = SCSubtractWindows(lost, [self windowsForSchedule: newSchedule overlappingFrom: date to: noticeEnd]);
            }
            NSDate* firstLost = SCFirstMomentInWindows(lost, date, noticeEnd);
            if (firstLost != nil) {
                NSString* name = [self displayNameForSchedule: oldSchedule];
                if ([firstLost timeIntervalSinceDate: date] < 1) {
                    why = [NSString stringWithFormat: @"loosens \"%@\" while it's active", name];
                } else {
                    NSDateFormatter* formatter = [NSDateFormatter new];
                    formatter.dateFormat = @"EEE h:mm a";
                    why = [NSString stringWithFormat: @"loosens \"%@\" at %@, less than %ld hours from now",
                           name, [formatter stringFromDate: firstLost], (long)(SCScheduleChangeNoticeMinutes / 60)];
                }
                break;
            }
        }

        // tightening: anything that adds restriction must use short windows
        if (newSchedule != nil && [self windowMinutesForSchedule: newSchedule] > SCPasswordlessMaxMinutes) {
            BOOL addsRestriction = YES;
            if (bothExist && !sitesAdded && !settingsChanged) {
                NSDate* horizon = [self comparisonHorizonForSchedules: @[oldSchedule, newSchedule] atDate: date];
                NSArray* gained = SCSubtractWindows([self windowsForSchedule: newSchedule overlappingFrom: date to: horizon],
                                                    [self windowsForSchedule: oldSchedule overlappingFrom: date to: horizon]);
                addsRestriction = SCFirstMomentInWindows(gained, date, horizon) != nil;
            }
            if (addsRestriction) {
                why = [NSString stringWithFormat: @"adds a block window longer than %ld minutes", (long)SCPasswordlessMaxMinutes];
                break;
            }
        }
    }
    if (reason != NULL) *reason = why;
    return why == nil;
}

+ (NSArray<NSArray<NSDate*>*>*)windowsForSchedule:(NSDictionary*)schedule overlappingFrom:(NSDate*)from to:(NSDate*)to {
    NSMutableArray* windows = [NSMutableArray array];
    if (![schedule[SCScheduleKeyEnabled] boolValue] || [from compare: to] != NSOrderedAscending) return windows;

    if ([self isOneOffSchedule: schedule]) {
        NSDate *start, *end;
        if ([self oneOffWindowForSchedule: schedule start: &start end: &end]
            && [end compare: from] == NSOrderedDescending && [start compare: to] == NSOrderedAscending) {
            [windows addObject: @[start, end]];
        }
        return windows;
    }

    NSSet* weekdays = [NSSet setWithArray: [self normalizedWeekdays: schedule[SCScheduleKeyWeekdays]]];
    NSInteger startMinute = [schedule[SCScheduleKeyStartMinute] integerValue];
    NSInteger endMinute = [schedule[SCScheduleKeyEndMinute] integerValue];
    if (weekdays.count == 0 || startMinute == endMinute) return windows;
    BOOL overnight = endMinute <= startMinute;
    NSSet* skipDates = [NSSet setWithArray: [self skipDatesForSchedule: schedule]];

    NSCalendar* cal = [self calendar];
    NSInteger days = [cal components: NSCalendarUnitDay fromDate: [cal startOfDayForDate: from] toDate: [cal startOfDayForDate: to] options: 0].day;
    // start a day early: yesterday's window can still be running if it crosses midnight
    for (NSInteger offset = -1; offset <= days; offset++) {
        NSDate* windowStart = [self dateOnDay: from dayOffset: offset minute: startMinute calendar: cal];
        if ([windowStart compare: to] != NSOrderedAscending) break;
        if (![weekdays containsObject: @([cal component: NSCalendarUnitWeekday fromDate: windowStart])]) continue;
        NSDate* windowEnd = [self dateOnDay: from dayOffset: offset + (overnight ? 1 : 0) minute: endMinute calendar: cal];
        if ([windowEnd compare: from] != NSOrderedDescending) continue;
        if (skipDates.count > 0 && [skipDates containsObject: [self dateStringForDate: windowStart]]) continue;
        [windows addObject: @[windowStart, windowEnd]];
    }
    return windows;
}

+ (NSDate*)activeWindowEndForSchedule:(NSDictionary*)schedule atDate:(NSDate*)date {
    NSDate* latestEnd = nil;
    for (NSArray<NSDate*>* window in [self windowsForSchedule: schedule overlappingFrom: date to: [date dateByAddingTimeInterval: 0.001]]) {
        if ([date compare: window[0]] == NSOrderedAscending) continue;
        latestEnd = latestEnd ? [latestEnd laterDate: window[1]] : window[1];
    }
    return latestEnd;
}

+ (NSDate*)lockDateForSchedule:(NSDictionary*)schedule atDate:(NSDate*)date {
    if ([self activeWindowEndForSchedule: schedule atDate: date] != nil) return date;
    NSDate* next = [self nextWindowStartForSchedule: schedule afterDate: date];
    return [next dateByAddingTimeInterval: -SCScheduleChangeNoticeMinutes * 60];
}

+ (BOOL)scheduleIsActive:(NSDictionary*)schedule atDate:(NSDate*)date {
    return [self activeWindowEndForSchedule: schedule atDate: date] != nil;
}

+ (NSArray<NSDictionary*>*)activeSchedules:(NSArray*)schedules atDate:(NSDate*)date {
    NSMutableArray* active = [NSMutableArray array];
    for (NSDictionary* schedule in schedules) {
        if ([schedule isKindOfClass: [NSDictionary class]] && [self scheduleIsActive: schedule atDate: date]) {
            [active addObject: schedule];
        }
    }
    return active;
}

+ (NSDate*)nextWindowStartForSchedule:(NSDictionary*)schedule afterDate:(NSDate*)date {
    if (![schedule[SCScheduleKeyEnabled] boolValue]) return nil;
    if ([self isOneOffSchedule: schedule]) {
        NSDate *start, *end;
        if (![self oneOffWindowForSchedule: schedule start: &start end: &end]) return nil;
        return [start compare: date] == NSOrderedDescending ? start : nil;
    }
    // look a week or so at a time; skipped days can push the next window out further
    NSCalendar* cal = [self calendar];
    NSDate* from = date;
    for (NSUInteger chunk = 0; chunk < 60; chunk++) {
        NSDate* to = [cal dateByAddingUnit: NSCalendarUnitDay value: 8 toDate: from options: 0];
        for (NSArray<NSDate*>* window in [self windowsForSchedule: schedule overlappingFrom: from to: to]) {
            if ([window[0] compare: date] == NSOrderedDescending) return window[0];
        }
        if ([self skipDatesForSchedule: schedule].count == 0) return nil;
        from = to;
    }
    return nil;
}

+ (BOOL)anyEnabledSchedules:(NSArray*)schedules {
    for (NSDictionary* schedule in schedules) {
        if ([schedule isKindOfClass: [NSDictionary class]] && [schedule[SCScheduleKeyEnabled] boolValue]) return YES;
    }
    return NO;
}

+ (NSDictionary*)scheduleWithID:(NSString*)scheduleID inSchedules:(NSArray*)schedules {
    for (NSDictionary* schedule in schedules) {
        if ([schedule isKindOfClass: [NSDictionary class]] && [schedule[SCScheduleKeyID] isEqual: scheduleID]) return schedule;
    }
    return nil;
}

#pragma mark - Descriptions

+ (NSString*)daysDescriptionForSchedule:(NSDictionary*)schedule {
    if ([self isOneOffSchedule: schedule]) {
        NSDateComponents* comps = [self dateComponentsFromDateString: schedule[SCScheduleKeyDate]];
        if (comps == nil) return schedule[SCScheduleKeyDate];
        NSCalendar* cal = [NSCalendar currentCalendar];
        NSDate* day = [cal dateFromComponents: comps];
        if ([cal isDateInToday: day]) return @"Today only";
        if ([cal isDateInTomorrow: day]) return @"Tomorrow only";
        NSDateFormatter* formatter = [NSDateFormatter new];
        formatter.dateFormat = @"EEE, MMM d";
        return [formatter stringFromDate: day];
    }
    NSArray<NSNumber*>* days = [self normalizedWeekdays: schedule[SCScheduleKeyWeekdays]];
    NSSet* set = [NSSet setWithArray: days];
    if (set.count == 7) return @"Every day";
    if ([set isEqualToSet: [NSSet setWithArray: @[@2, @3, @4, @5, @6]]]) return @"Weekdays";
    if ([set isEqualToSet: [NSSet setWithArray: @[@1, @7]]]) return @"Weekends";

    // work in Monday-first order, treating the week as circular so e.g. Sun-Thu reads "Sun–Thu"
    NSArray<NSString*>* symbols = [[NSDateFormatter new] shortWeekdaySymbols];
    NSArray<NSNumber*>* mondayFirst = @[@2, @3, @4, @5, @6, @7, @1];
    BOOL selected[7];
    for (NSUInteger i = 0; i < 7; i++) selected[i] = [set containsObject: mondayFirst[i]];
    NSString* (^nameAt)(NSUInteger) = ^NSString*(NSUInteger i) {
        return symbols[(NSUInteger)(mondayFirst[i % 7].integerValue - 1)];
    };

    NSMutableArray* parts = [NSMutableArray array];
    for (NSUInteger start = 0; start < 7; start++) {
        // a run starts where this day is selected and the previous (circular) day isn't
        if (!selected[start] || selected[(start + 6) % 7]) continue;
        NSUInteger length = 0;
        while (length < 7 && selected[(start + length) % 7]) length++;
        if (length >= 3) {
            [parts addObject: [NSString stringWithFormat: @"%@–%@", nameAt(start), nameAt(start + length - 1)]];
        } else {
            for (NSUInteger i = 0; i < length; i++) [parts addObject: nameAt(start + i)];
        }
    }
    return [parts componentsJoinedByString: @", "];
}

+ (NSString*)timeStringForMinute:(NSInteger)minute {
    static NSDateFormatter* formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterNoStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
    });
    NSDate* date = [NSDate dateWithTimeIntervalSinceReferenceDate: (minute % kMinutesPerDay) * 60];
    return [formatter stringFromDate: date];
}

+ (NSString*)timeDescriptionForSchedule:(NSDictionary*)schedule {
    NSInteger start = [schedule[SCScheduleKeyStartMinute] integerValue];
    NSInteger end = [schedule[SCScheduleKeyEndMinute] integerValue];
    NSString* desc = [NSString stringWithFormat: @"%@ – %@", [self timeStringForMinute: start], [self timeStringForMinute: end]];
    if (end <= start) desc = [desc stringByAppendingString: @" (next day)"];
    return desc;
}

+ (NSString*)displayNameForSchedule:(NSDictionary*)schedule {
    NSString* name = schedule[SCScheduleKeyName];
    if ([name isKindOfClass: [NSString class]] && name.length > 0) return name;
    return [NSString stringWithFormat: @"%@ %@", [self daysDescriptionForSchedule: schedule], [self timeDescriptionForSchedule: schedule]];
}

+ (NSString*)skipDescriptionForSchedule:(NSDictionary*)schedule {
    NSArray<NSString*>* skipDates = [self skipDatesForSchedule: schedule];
    if (skipDates.count == 0) return @"";
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"EEE, MMM d";
    NSMutableArray* names = [NSMutableArray array];
    for (NSString* day in skipDates) {
        NSDate* date = [self dateForDateString: day];
        [names addObject: date ? [formatter stringFromDate: date] : day];
    }
    if (names.count == 1) return [NSString stringWithFormat: @"skips %@", names[0]];
    NSString* last = names.lastObject;
    [names removeLastObject];
    return [NSString stringWithFormat: @"skips %@ and %@", [names componentsJoinedByString: @", "], last];
}

#pragma mark - Parsing

+ (NSInteger)weekdayFromToken:(NSString*)token {
    if (token.length < 2) return 0;
    NSDictionary* map = @{ @"su": @1, @"mo": @2, @"tu": @3, @"we": @4, @"th": @5, @"fr": @6, @"sa": @7 };
    NSNumber* day = map[[token substringToIndex: 2]];
    if (day == nil) return 0;
    // make sure the rest of the token is a prefix of the day's full name (so "mon", "monday" work; "mox" doesn't)
    NSArray* fullNames = @[@"sunday", @"monday", @"tuesday", @"wednesday", @"thursday", @"friday", @"saturday"];
    NSString* fullName = fullNames[(NSUInteger)(day.integerValue - 1)];
    return [fullName hasPrefix: token] ? day.integerValue : 0;
}

+ (NSArray<NSNumber*>*)weekdaysFromString:(NSString*)string {
    NSString* str = [[string lowercaseString] stringByReplacingOccurrencesOfString: @" " withString: @""];
    if ([@[@"daily", @"everyday", @"all"] containsObject: str]) return @[@1, @2, @3, @4, @5, @6, @7];
    if ([str isEqualToString: @"weekdays"]) return @[@2, @3, @4, @5, @6];
    if ([str isEqualToString: @"weekends"]) return @[@1, @7];

    NSMutableSet<NSNumber*>* days = [NSMutableSet set];
    for (NSString* part in [str componentsSeparatedByString: @","]) {
        if (part.length == 0) continue;
        NSArray<NSString*>* range = [part componentsSeparatedByString: @"-"];
        if (range.count == 1) {
            NSInteger day = [self weekdayFromToken: range[0]];
            if (day == 0) return nil;
            [days addObject: @(day)];
        } else if (range.count == 2) {
            NSInteger from = [self weekdayFromToken: range[0]];
            NSInteger to = [self weekdayFromToken: range[1]];
            if (from == 0 || to == 0) return nil;
            // ranges can wrap around the week, e.g. fri-mon
            for (NSInteger day = from; ; day = (day % 7) + 1) {
                [days addObject: @(day)];
                if (day == to) break;
            }
        } else {
            return nil;
        }
    }
    if (days.count == 0) return nil;
    return [[days allObjects] sortedArrayUsingSelector: @selector(compare:)];
}

+ (NSInteger)minuteFromTimeString:(NSString*)string {
    NSString* str = [[string lowercaseString] stringByReplacingOccurrencesOfString: @" " withString: @""];
    if ([str isEqualToString: @"noon"]) return 12 * 60;
    if ([str isEqualToString: @"midnight"]) return 0;

    NSInteger meridiem = 0; // 0 = 24h, 1 = am, 2 = pm
    if ([str hasSuffix: @"am"] || [str hasSuffix: @"pm"]) {
        meridiem = [str hasSuffix: @"am"] ? 1 : 2;
        str = [str substringToIndex: str.length - 2];
    } else if ([str hasSuffix: @"a"] || [str hasSuffix: @"p"]) {
        meridiem = [str hasSuffix: @"a"] ? 1 : 2;
        str = [str substringToIndex: str.length - 1];
    }

    NSArray<NSString*>* parts = [str componentsSeparatedByString: @":"];
    if (parts.count < 1 || parts.count > 2) return -1;
    NSCharacterSet* nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString* part in parts) {
        if (part.length == 0 || part.length > 2 || [part rangeOfCharacterFromSet: nonDigits].location != NSNotFound) return -1;
    }
    if (parts.count == 2 && parts[1].length != 2) return -1;

    NSInteger hour = [parts[0] integerValue];
    NSInteger minute = parts.count == 2 ? [parts[1] integerValue] : 0;
    if (minute > 59) return -1;
    if (meridiem == 0) {
        if (hour > 23) return -1;
    } else {
        if (hour < 1 || hour > 12) return -1;
        if (hour == 12) hour = 0;
        if (meridiem == 2) hour += 12;
    }
    return hour * 60 + minute;
}

@end
