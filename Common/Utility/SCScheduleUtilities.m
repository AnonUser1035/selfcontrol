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

NSUInteger const SCScheduleMaxCount = 50;

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

    id weekdays = schedule[SCScheduleKeyWeekdays];
    if (![weekdays isKindOfClass: [NSArray class]] || [weekdays count] == 0) {
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
            || [newSchedule[SCScheduleKeyStartMinute] integerValue] != [oldSchedule[SCScheduleKeyStartMinute] integerValue]
            || [newSchedule[SCScheduleKeyEndMinute] integerValue] != [oldSchedule[SCScheduleKeyEndMinute] integerValue]
            || ![[NSSet setWithArray: oldSchedule[SCScheduleKeyBlocklist] ?: @[]] isSubsetOfSet: [NSSet setWithArray: newSchedule[SCScheduleKeyBlocklist] ?: @[]]];

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

+ (NSDate*)activeWindowEndForSchedule:(NSDictionary*)schedule atDate:(NSDate*)date {
    if (![schedule[SCScheduleKeyEnabled] boolValue]) return nil;
    NSSet* weekdays = [NSSet setWithArray: [self normalizedWeekdays: schedule[SCScheduleKeyWeekdays]]];
    NSInteger startMinute = [schedule[SCScheduleKeyStartMinute] integerValue];
    NSInteger endMinute = [schedule[SCScheduleKeyEndMinute] integerValue];
    if (weekdays.count == 0 || startMinute == endMinute) return nil;
    BOOL overnight = endMinute <= startMinute;

    NSCalendar* cal = [self calendar];
    NSDate* latestEnd = nil;
    // a window that started yesterday can still be running today if it crosses midnight
    for (NSInteger offset = overnight ? -1 : 0; offset <= 0; offset++) {
        NSDate* windowStart = [self dateOnDay: date dayOffset: offset minute: startMinute calendar: cal];
        NSInteger weekday = [cal component: NSCalendarUnitWeekday fromDate: windowStart];
        if (![weekdays containsObject: @(weekday)]) continue;

        NSDate* windowEnd = [self dateOnDay: date dayOffset: offset + (overnight ? 1 : 0) minute: endMinute calendar: cal];
        if ([date compare: windowStart] != NSOrderedAscending && [date compare: windowEnd] == NSOrderedAscending) {
            if (latestEnd == nil || [windowEnd compare: latestEnd] == NSOrderedDescending) {
                latestEnd = windowEnd;
            }
        }
    }
    return latestEnd;
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
    NSSet* weekdays = [NSSet setWithArray: [self normalizedWeekdays: schedule[SCScheduleKeyWeekdays]]];
    if (weekdays.count == 0) return nil;
    NSInteger startMinute = [schedule[SCScheduleKeyStartMinute] integerValue];

    NSCalendar* cal = [self calendar];
    for (NSInteger offset = 0; offset <= 7; offset++) {
        NSDate* windowStart = [self dateOnDay: date dayOffset: offset minute: startMinute calendar: cal];
        NSInteger weekday = [cal component: NSCalendarUnitWeekday fromDate: windowStart];
        if ([weekdays containsObject: @(weekday)] && [windowStart compare: date] == NSOrderedDescending) {
            return windowStart;
        }
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
