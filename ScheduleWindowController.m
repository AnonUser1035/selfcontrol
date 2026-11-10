//
//  ScheduleWindowController.m
//  SelfControl
//
//  fork: window for managing recurring scheduled blocks.
//

#import "ScheduleWindowController.h"
#import "SCXPCClient.h"
#import "SCScheduleUtilities.h"
#import "SCUIUtilities.h"

static NSInteger const kMinutesPerDay = 24 * 60;

static NSArray<NSString*>* SCBlockSettingKeys(void) {
    return @[@"ClearCaches", @"AllowLocalNetworks", @"EvaluateCommonSubdomains", @"IncludeLinkedDomains",
             @"BlockSoundShouldPlay", @"BlockSound", @"EnableErrorReporting"];
}

// errors from the daemon don't have access to our .strings, so re-create them here (same as SCUIUtilities)
static NSError* SCDisplayableError(NSError* err) {
    if ([err.domain isEqualToString: kSelfControlErrorDomain] && [err.userInfo[@"SCDescriptionNotFound"] boolValue]) {
        return [SCErr errorWithCode: err.code];
    }
    return err;
}

static NSTextField* SCLabel(NSString* text, NSRect frame) {
    NSTextField* label = [NSTextField labelWithString: text];
    label.frame = frame;
    return label;
}

#pragma mark - Editor sheet

@interface ScheduleEditorController : NSWindowController

@property (nonatomic, copy, nullable) void (^onSave)(NSDictionary* schedule, ScheduleEditorController* editor);

- (instancetype)initWithSchedule:(nullable NSDictionary*)schedule
                defaultBlocklist:(NSArray<NSString*>*)defaultBlocklist
                   blockSettings:(NSDictionary*)blockSettings;
- (void)setBusy:(BOOL)busy;
// for an active schedule: days and times can't change, but sites can still be added
- (void)lockTimingWithNote:(NSString*)note;

@end

@implementation ScheduleEditorController {
    NSTextField* _headerLabel;
    NSArray<NSButton*>* _presetButtons;
    NSDictionary* _originalSchedule;
    NSDictionary* _blockSettings;
    NSTextField* _nameField;
    NSArray<NSButton*>* _dayButtons;
    NSDatePicker* _startPicker;
    NSDatePicker* _endPicker;
    NSTextField* _overnightLabel;
    NSTextView* _sitesView;
    NSButton* _saveButton;
    NSButton* _cancelButton;
    NSProgressIndicator* _spinner;
}

- (instancetype)initWithSchedule:(NSDictionary*)schedule defaultBlocklist:(NSArray<NSString*>*)defaultBlocklist blockSettings:(NSDictionary*)blockSettings {
    NSWindow* window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 560, 470)
                                                   styleMask: NSWindowStyleMaskTitled
                                                     backing: NSBackingStoreBuffered
                                                       defer: YES];
    if (self = [super initWithWindow: window]) {
        _originalSchedule = [schedule copy];
        _blockSettings = [blockSettings copy];
        [self buildInterface];

        if (schedule != nil) {
            _nameField.stringValue = schedule[SCScheduleKeyName] ?: @"";
            [self setSelectedDays: schedule[SCScheduleKeyWeekdays]];
            [self setMinute: [schedule[SCScheduleKeyStartMinute] integerValue] onPicker: _startPicker];
            [self setMinute: [schedule[SCScheduleKeyEndMinute] integerValue] onPicker: _endPicker];
            _sitesView.string = [schedule[SCScheduleKeyBlocklist] componentsJoinedByString: @"\n"];
        } else {
            [self setSelectedDays: @[@2, @3, @4, @5, @6]];
            [self setMinute: 9 * 60 onPicker: _startPicker];
            [self setMinute: 17 * 60 onPicker: _endPicker];
            _sitesView.string = [defaultBlocklist componentsJoinedByString: @"\n"];
        }
        [self timeChanged: nil];
    }
    return self;
}

- (void)buildInterface {
    NSView* content = self.window.contentView;
    CGFloat fieldX = 110;

    _headerLabel = SCLabel(_originalSchedule ? @"Edit Schedule" : @"New Schedule", NSMakeRect(20, 432, 520, 20));
    _headerLabel.font = [NSFont boldSystemFontOfSize: 14];
    [content addSubview: _headerLabel];

    [content addSubview: SCLabel(@"Name:", NSMakeRect(20, 397, 85, 17))];
    _nameField = [[NSTextField alloc] initWithFrame: NSMakeRect(fieldX, 394, 430, 22)];
    _nameField.placeholderString = @"Optional, e.g. Work hours";
    [content addSubview: _nameField];

    [content addSubview: SCLabel(@"Days:", NSMakeRect(20, 360, 85, 17))];
    NSArray<NSString*>* symbols = [[NSDateFormatter new] shortWeekdaySymbols];
    NSMutableArray* dayButtons = [NSMutableArray array];
    NSArray<NSNumber*>* mondayFirst = @[@2, @3, @4, @5, @6, @7, @1];
    for (NSUInteger i = 0; i < mondayFirst.count; i++) {
        NSInteger weekday = mondayFirst[i].integerValue;
        NSButton* box = [NSButton checkboxWithTitle: symbols[(NSUInteger)(weekday - 1)] target: nil action: nil];
        box.frame = NSMakeRect(fieldX + i * 62, 358, 60, 20);
        box.tag = weekday;
        [content addSubview: box];
        [dayButtons addObject: box];
    }
    _dayButtons = dayButtons;

    NSArray* presets = @[@[@"Weekdays", @[@2, @3, @4, @5, @6]], @[@"Weekends", @[@1, @7]], @[@"Every day", @[@1, @2, @3, @4, @5, @6, @7]]];
    NSMutableArray* presetButtons = [NSMutableArray array];
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSButton* preset = [NSButton buttonWithTitle: presets[i][0] target: self action: @selector(applyPreset:)];
        preset.controlSize = NSControlSizeSmall;
        preset.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
        preset.frame = NSMakeRect(fieldX - 6 + i * 92, 326, 90, 24);
        preset.tag = (NSInteger)i;
        [content addSubview: preset];
        [presetButtons addObject: preset];
    }
    _presetButtons = presetButtons;

    [content addSubview: SCLabel(@"From:", NSMakeRect(20, 293, 85, 17))];
    _startPicker = [self timePickerWithFrame: NSMakeRect(fieldX, 288, 100, 27)];
    [content addSubview: _startPicker];
    [content addSubview: SCLabel(@"to", NSMakeRect(fieldX + 110, 293, 20, 17))];
    _endPicker = [self timePickerWithFrame: NSMakeRect(fieldX + 135, 288, 100, 27)];
    [content addSubview: _endPicker];
    _overnightLabel = SCLabel(@"", NSMakeRect(fieldX + 245, 293, 130, 17));
    _overnightLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview: _overnightLabel];

    [content addSubview: SCLabel(@"Sites to block, one per line:", NSMakeRect(20, 258, 520, 17))];
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(20, 64, 520, 188)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    _sitesView = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, scroll.contentSize.width, scroll.contentSize.height)];
    _sitesView.font = [NSFont monospacedSystemFontOfSize: 12 weight: NSFontWeightRegular];
    _sitesView.autoresizingMask = NSViewWidthSizable;
    _sitesView.richText = NO;
    _sitesView.automaticQuoteSubstitutionEnabled = NO;
    _sitesView.automaticDashSubstitutionEnabled = NO;
    _sitesView.automaticTextReplacementEnabled = NO;
    _sitesView.automaticSpellingCorrectionEnabled = NO;
    _sitesView.automaticLinkDetectionEnabled = NO;
    scroll.documentView = _sitesView;
    [content addSubview: scroll];

    _spinner = [[NSProgressIndicator alloc] initWithFrame: NSMakeRect(20, 22, 16, 16)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    [content addSubview: _spinner];

    _cancelButton = [NSButton buttonWithTitle: @"Cancel" target: self action: @selector(cancel:)];
    _cancelButton.frame = NSMakeRect(350, 13, 96, 32);
    _cancelButton.keyEquivalent = @"\033";
    [content addSubview: _cancelButton];

    _saveButton = [NSButton buttonWithTitle: @"Save" target: self action: @selector(save:)];
    _saveButton.frame = NSMakeRect(450, 13, 96, 32);
    _saveButton.keyEquivalent = @"\r";
    [content addSubview: _saveButton];

    self.window.initialFirstResponder = _nameField;
}

- (NSDatePicker*)timePickerWithFrame:(NSRect)frame {
    // the pickers work in GMT on the reference date, so they represent a pure wall-clock time with no DST effects
    NSCalendar* calendar = [[NSCalendar alloc] initWithCalendarIdentifier: NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
    NSDatePicker* picker = [[NSDatePicker alloc] initWithFrame: frame];
    picker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    picker.datePickerElements = NSDatePickerElementFlagHourMinute;
    picker.calendar = calendar;
    picker.timeZone = calendar.timeZone;
    picker.target = self;
    picker.action = @selector(timeChanged:);
    return picker;
}

- (void)setMinute:(NSInteger)minute onPicker:(NSDatePicker*)picker {
    picker.dateValue = [NSDate dateWithTimeIntervalSinceReferenceDate: minute * 60];
}

- (NSInteger)minuteFromPicker:(NSDatePicker*)picker {
    NSInteger minute = (NSInteger)floor(picker.dateValue.timeIntervalSinceReferenceDate / 60.0) % kMinutesPerDay;
    return minute < 0 ? minute + kMinutesPerDay : minute;
}

- (void)setSelectedDays:(NSArray<NSNumber*>*)days {
    for (NSButton* box in _dayButtons) {
        box.state = [days containsObject: @(box.tag)] ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (IBAction)applyPreset:(NSButton*)sender {
    NSArray* presetDays = @[@[@2, @3, @4, @5, @6], @[@1, @7], @[@1, @2, @3, @4, @5, @6, @7]];
    [self setSelectedDays: presetDays[(NSUInteger)sender.tag]];
}

- (IBAction)timeChanged:(id)sender {
    NSInteger start = [self minuteFromPicker: _startPicker];
    NSInteger end = [self minuteFromPicker: _endPicker];
    if (start == end) {
        _overnightLabel.stringValue = @"must differ";
    } else if (end < start) {
        _overnightLabel.stringValue = @"ends next day";
    } else {
        _overnightLabel.stringValue = @"";
    }
}

- (NSArray<NSString*>*)enteredSites {
    NSMutableOrderedSet* sites = [NSMutableOrderedSet orderedSet];
    for (NSString* line in [_sitesView.string componentsSeparatedByCharactersInSet: [NSCharacterSet newlineCharacterSet]]) {
        [sites addObjectsFromArray: [SCMiscUtilities cleanBlocklistEntry: line]];
    }
    return sites.array;
}

- (void)setBusy:(BOOL)busy {
    _saveButton.enabled = !busy;
    _cancelButton.enabled = !busy;
    if (busy) [_spinner startAnimation: nil]; else [_spinner stopAnimation: nil];
}

- (void)lockTimingWithNote:(NSString*)note {
    for (NSButton* button in [_dayButtons arrayByAddingObjectsFromArray: _presetButtons]) button.enabled = NO;
    _startPicker.enabled = NO;
    _endPicker.enabled = NO;
    _headerLabel.stringValue = [NSString stringWithFormat: @"Edit Schedule (%@)", note];
}

- (IBAction)cancel:(id)sender {
    [self.window.sheetParent endSheet: self.window returnCode: NSModalResponseCancel];
}

- (IBAction)save:(id)sender {
    [self.window makeFirstResponder: nil]; // commit any in-progress edit

    NSMutableArray<NSNumber*>* days = [NSMutableArray array];
    for (NSButton* box in _dayButtons) {
        if (box.state == NSControlStateValueOn) [days addObject: @(box.tag)];
    }
    NSString* name = [_nameField.stringValue stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSMutableDictionary* schedule;
    if (_originalSchedule != nil) {
        schedule = [_originalSchedule mutableCopy];
        schedule[SCScheduleKeyWeekdays] = [days sortedArrayUsingSelector: @selector(compare:)];
        schedule[SCScheduleKeyStartMinute] = @([self minuteFromPicker: _startPicker]);
        schedule[SCScheduleKeyEndMinute] = @([self minuteFromPicker: _endPicker]);
        schedule[SCScheduleKeyBlocklist] = [self enteredSites];
        if (name.length > 0) schedule[SCScheduleKeyName] = name; else [schedule removeObjectForKey: SCScheduleKeyName];
    } else {
        schedule = [SCScheduleUtilities scheduleWithName: name
                                                weekdays: days
                                             startMinute: [self minuteFromPicker: _startPicker]
                                               endMinute: [self minuteFromPicker: _endPicker]
                                               blocklist: [self enteredSites]
                                           blockSettings: _blockSettings];
    }

    NSError* err = [SCScheduleUtilities validateSchedule: schedule];
    if (err != nil) {
        [[NSAlert alertWithError: err] beginSheetModalForWindow: self.window completionHandler: nil];
        return;
    }
    if (self.onSave != nil) self.onSave(schedule, self);
}

@end

#pragma mark - Schedules window

@interface ScheduleWindowController ()

@property (nonatomic, strong) SCXPCClient* xpc;
@property (nonatomic, copy) NSArray<NSDictionary*>* schedules;
@property (nonatomic, strong, nullable) ScheduleEditorController* activeEditor;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) NSTimer* statusTimer;

@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSTextField* emptyLabel;
@property (nonatomic, strong) NSButton* addButton;
@property (nonatomic, strong) NSButton* editButton;
@property (nonatomic, strong) NSButton* removeButton;
@property (nonatomic, strong) NSProgressIndicator* spinner;

@end

@implementation ScheduleWindowController

- (instancetype)initWithXPCClient:(SCXPCClient*)xpc {
    NSWindow* window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 880, 420)
                                                   styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing: NSBackingStoreBuffered
                                                       defer: YES];
    window.title = @"Schedules";
    window.contentMinSize = NSMakeSize(760, 300);
    window.releasedWhenClosed = NO;

    if (self = [super initWithWindow: window]) {
        _xpc = xpc;
        _schedules = @[];
        [self buildInterface];
        if (![window setFrameUsingName: @"SCSchedulesWindow"]) [window center];
        window.frameAutosaveName = @"SCSchedulesWindow";
        [self refresh];

        // keep the status column ("Active until…", "Next…") current
        __weak typeof(self) weakSelf = self;
        _statusTimer = [NSTimer scheduledTimerWithTimeInterval: 30 repeats: YES block:^(NSTimer* timer) {
            if (weakSelf.window.isVisible) [weakSelf refresh];
        }];
        _statusTimer.tolerance = 5;
    }
    return self;
}

- (void)dealloc {
    [_statusTimer invalidate];
}

- (void)buildInterface {
    NSView* content = self.window.contentView;
    NSRect bounds = content.bounds;

    NSTextField* info = [NSTextField wrappingLabelWithString:
        @"Scheduled blocks start automatically, even when SelfControl is closed. If a block is already running, "
        @"it's extended to cover the schedule and the schedule's sites are added. A schedule can't be removed, "
        @"turned off or shortened while it's active."];
    info.frame = NSMakeRect(20, bounds.size.height - 62, bounds.size.width - 40, 48);
    info.textColor = [NSColor secondaryLabelColor];
    info.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview: info];

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(20, 56, bounds.size.width - 40, bounds.size.height - 128)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTableView* table = [[NSTableView alloc] initWithFrame: scroll.bounds];
    table.style = NSTableViewStyleFullWidth;
    table.rowHeight = 24;
    table.usesAlternatingRowBackgroundColors = YES;
    table.allowsMultipleSelection = NO;
    table.allowsEmptySelection = YES;
    table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    NSArray* columns = @[@[@"enabled", @"On", @30], @[@"name", @"Name", @130], @[@"days", @"Days", @140],
                         @[@"time", @"Time", @200], @[@"sites", @"Sites", @44], @[@"status", @"Status", @180]];
    for (NSArray* spec in columns) {
        NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier: spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = MIN(34, column.width);
        [table addTableColumn: column];
    }
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(editSchedule:);
    scroll.documentView = table;
    [content addSubview: scroll];
    self.tableView = table;

    self.emptyLabel = [NSTextField labelWithString: @"No schedules yet. Click Add… to create one."];
    self.emptyLabel.textColor = [NSColor secondaryLabelColor];
    self.emptyLabel.alignment = NSTextAlignmentCenter;
    self.emptyLabel.frame = NSMakeRect(20, NSMidY(scroll.frame) - 10, bounds.size.width - 40, 20);
    self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
    [content addSubview: self.emptyLabel positioned: NSWindowAbove relativeTo: scroll];

    self.addButton = [NSButton buttonWithTitle: @"Add…" target: self action: @selector(addSchedule:)];
    self.addButton.frame = NSMakeRect(14, 13, 96, 32);
    [content addSubview: self.addButton];

    self.editButton = [NSButton buttonWithTitle: @"Edit…" target: self action: @selector(editSchedule:)];
    self.editButton.frame = NSMakeRect(110, 13, 96, 32);
    [content addSubview: self.editButton];

    self.removeButton = [NSButton buttonWithTitle: @"Remove" target: self action: @selector(removeSchedule:)];
    self.removeButton.frame = NSMakeRect(206, 13, 96, 32);
    [content addSubview: self.removeButton];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame: NSMakeRect(bounds.size.width - 36, 21, 16, 16)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.autoresizingMask = NSViewMinXMargin;
    [content addSubview: self.spinner];
}

#pragma mark Data

- (void)refresh {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
        return;
    }
    if (self.busy) return; // don't clobber an in-flight change

    id stored = [[SCSettings sharedSettings] valueForKey: @"Schedules"];
    self.schedules = [stored isKindOfClass: [NSArray class]] ? stored : @[];
    [self reloadTable];
}

- (void)reloadTable {
    NSInteger selectedRow = self.tableView.selectedRow;
    [self.tableView reloadData];
    if (selectedRow >= 0 && selectedRow < (NSInteger)self.schedules.count) {
        [self.tableView selectRowIndexes: [NSIndexSet indexSetWithIndex: (NSUInteger)selectedRow] byExtendingSelection: NO];
    }
    self.emptyLabel.hidden = self.schedules.count > 0;
    [self updateButtons];
}

- (NSDictionary*)selectedSchedule {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.schedules.count) return nil;
    return self.schedules[(NSUInteger)row];
}

- (void)updateButtons {
    NSDictionary* selected = [self selectedSchedule];
    BOOL selectedActive = selected != nil && [SCScheduleUtilities scheduleIsActive: selected atDate: [NSDate date]];
    self.addButton.enabled = !self.busy && self.schedules.count < SCScheduleMaxCount;
    // an active schedule can still get more sites, so Edit stays available; Remove doesn't
    self.editButton.enabled = !self.busy && selected != nil;
    self.removeButton.enabled = !self.busy && selected != nil && !selectedActive;
    self.removeButton.toolTip = selectedActive ? @"This schedule is active. You can remove it after it ends." : nil;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (busy) [self.spinner startAnimation: nil]; else [self.spinner stopAnimation: nil];
    [self.tableView reloadData];
    [self updateButtons];
}

- (NSDictionary*)currentBlockSettings {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary* blockSettings = [NSMutableDictionary dictionary];
    for (NSString* key in SCBlockSettingKeys()) {
        id value = [defaults objectForKey: key];
        if (value != nil) blockSettings[key] = value;
    }
    return blockSettings;
}

#pragma mark Saving

- (void)presentScheduleError:(NSError*)error {
    if (error == nil || [SCMiscUtilities errorIsAuthCanceled: error]) return;
    NSWindow* host = self.activeEditor.window ?: self.window;
    [[NSAlert alertWithError: SCDisplayableError(error)] beginSheetModalForWindow: host completionHandler: nil];
}

- (void)pushSchedules:(NSArray<NSDictionary*>*)newSchedules completion:(void(^)(BOOL success))completion {
    NSError* err = [SCScheduleUtilities validateSchedules: newSchedules];
    if (err == nil) {
        err = [SCScheduleUtilities validateChangeFromSchedules: self.schedules toSchedules: newSchedules atDate: [NSDate date]];
    }
    if (err != nil) {
        [self presentScheduleError: err];
        completion(NO);
        return;
    }

    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    void (^finish)(NSError*) = ^(NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.busy = NO;
            if (error != nil) {
                [strongSelf presentScheduleError: error];
                [strongSelf reloadTable]; // e.g. revert a checkbox that was clicked
                completion(NO);
                return;
            }
            // the daemon accepted exactly this list; show it now rather than waiting for the settings sync
            strongSelf.schedules = newSchedules;
            [strongSelf reloadTable];
            completion(YES);
        });
    };

    [self.xpc ensureDaemonInstalled:^(NSError* installErr) {
        if (installErr != nil) {
            finish(installErr);
            return;
        }
        [weakSelf.xpc updateSchedules: newSchedules reply:^(NSError* updateErr) {
            finish(updateErr);
        }];
    }];
}

- (void)runEditor:(ScheduleEditorController*)editor {
    self.activeEditor = editor;
    __weak typeof(self) weakSelf = self;
    editor.onSave = ^(NSDictionary* schedule, ScheduleEditorController* ed) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        NSMutableArray* updated = [strongSelf.schedules mutableCopy];
        NSDictionary* existing = [SCScheduleUtilities scheduleWithID: schedule[SCScheduleKeyID] inSchedules: updated];
        if (existing != nil) {
            updated[[updated indexOfObjectIdenticalTo: existing]] = schedule;
        } else {
            [updated addObject: schedule];
        }
        [ed setBusy: YES];
        [strongSelf pushSchedules: updated completion:^(BOOL success) {
            [ed setBusy: NO];
            if (success) [strongSelf.window endSheet: ed.window returnCode: NSModalResponseOK];
        }];
    };
    [self.window beginSheet: editor.window completionHandler:^(NSModalResponse returnCode) {
        weakSelf.activeEditor = nil;
    }];
}

#pragma mark Actions

- (IBAction)addSchedule:(id)sender {
    if (self.busy) return;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    // scheduled blocks are always blocklists, so only prefill from the main list if it isn't an allowlist
    NSArray* defaultSites = [defaults boolForKey: @"BlockAsWhitelist"] ? @[] : [SCMiscUtilities cleanBlocklist: [defaults arrayForKey: @"Blocklist"] ?: @[]];
    [self runEditor: [[ScheduleEditorController alloc] initWithSchedule: nil
                                                       defaultBlocklist: defaultSites
                                                          blockSettings: [self currentBlockSettings]]];
}

- (IBAction)editSchedule:(id)sender {
    NSDictionary* selected = [self selectedSchedule];
    if (self.busy || selected == nil) return;
    ScheduleEditorController* editor = [[ScheduleEditorController alloc] initWithSchedule: selected
                                                                         defaultBlocklist: @[]
                                                                            blockSettings: [self currentBlockSettings]];
    if ([SCScheduleUtilities scheduleIsActive: selected atDate: [NSDate date]]) {
        [editor lockTimingWithNote: @"active now: you can only add sites"];
    }
    [self runEditor: editor];
}

- (IBAction)removeSchedule:(id)sender {
    NSDictionary* selected = [self selectedSchedule];
    if (self.busy || selected == nil) return;

    NSAlert* alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat: @"Remove \"%@\"?", [SCScheduleUtilities displayNameForSchedule: selected]];
    alert.informativeText = @"This schedule will stop starting blocks.";
    [alert addButtonWithTitle: @"Remove"];
    [alert addButtonWithTitle: @"Cancel"];
    [alert beginSheetModalForWindow: self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray* updated = [self.schedules mutableCopy];
        [updated removeObjectIdenticalTo: selected];
        [self pushSchedules: updated completion:^(BOOL success) {}];
    }];
}

- (IBAction)toggleEnabled:(NSButton*)sender {
    NSInteger row = [self.tableView rowForView: sender];
    if (self.busy || row < 0 || row >= (NSInteger)self.schedules.count) return;
    NSMutableArray* updated = [self.schedules mutableCopy];
    NSMutableDictionary* schedule = [updated[(NSUInteger)row] mutableCopy];
    schedule[SCScheduleKeyEnabled] = @(sender.state == NSControlStateValueOn);
    updated[(NSUInteger)row] = schedule;
    [self pushSchedules: updated completion:^(BOOL success) {}];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return (NSInteger)self.schedules.count;
}

- (NSString*)statusForSchedule:(NSDictionary*)schedule textColor:(NSColor**)color {
    NSDate* now = [NSDate date];
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    *color = [NSColor labelColor];

    if (![schedule[SCScheduleKeyEnabled] boolValue]) {
        *color = [NSColor secondaryLabelColor];
        return @"Off";
    }
    NSDate* activeEnd = [SCScheduleUtilities activeWindowEndForSchedule: schedule atDate: now];
    if (activeEnd != nil) {
        *color = [NSColor systemOrangeColor];
        return [NSString stringWithFormat: @"Active until %@", [formatter stringFromDate: activeEnd]];
    }
    NSDate* next = [SCScheduleUtilities nextWindowStartForSchedule: schedule afterDate: now];
    if (next == nil) return @"";
    NSCalendar* calendar = [NSCalendar currentCalendar];
    NSString* day;
    if ([calendar isDateInToday: next]) day = @"today";
    else if ([calendar isDateInTomorrow: next]) day = @"tomorrow";
    else {
        NSDateFormatter* dayFormatter = [NSDateFormatter new];
        dayFormatter.dateFormat = @"EEE";
        day = [dayFormatter stringFromDate: next];
    }
    return [NSString stringWithFormat: @"Next: %@ %@", day, [formatter stringFromDate: next]];
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    NSDictionary* schedule = self.schedules[(NSUInteger)row];
    NSString* identifier = tableColumn.identifier;
    BOOL active = [SCScheduleUtilities scheduleIsActive: schedule atDate: [NSDate date]];

    if ([identifier isEqualToString: @"enabled"]) {
        NSButton* box = [tableView makeViewWithIdentifier: identifier owner: self];
        if (box == nil) {
            box = [NSButton checkboxWithTitle: @"" target: self action: @selector(toggleEnabled:)];
            box.identifier = identifier;
        }
        box.state = [schedule[SCScheduleKeyEnabled] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        box.enabled = !self.busy && !active;
        box.toolTip = active ? @"Active schedules can't be turned off until they end." : nil;
        return box;
    }

    NSTableCellView* cell = [tableView makeViewWithIdentifier: identifier owner: self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame: NSMakeRect(0, 0, tableColumn.width, tableView.rowHeight)];
        cell.identifier = identifier;
        NSTextField* text = [NSTextField labelWithString: @""];
        text.frame = NSMakeRect(2, (tableView.rowHeight - 17) / 2, tableColumn.width - 4, 17);
        text.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview: text];
        cell.textField = text;
    }

    NSColor* color = [NSColor labelColor];
    NSString* value = @"";
    if ([identifier isEqualToString: @"name"]) {
        value = schedule[SCScheduleKeyName] ?: @"";
    } else if ([identifier isEqualToString: @"days"]) {
        value = [SCScheduleUtilities daysDescriptionForSchedule: schedule];
    } else if ([identifier isEqualToString: @"time"]) {
        value = [SCScheduleUtilities timeDescriptionForSchedule: schedule];
    } else if ([identifier isEqualToString: @"sites"]) {
        value = [NSString stringWithFormat: @"%lu", (unsigned long)[schedule[SCScheduleKeyBlocklist] count]];
        cell.toolTip = [schedule[SCScheduleKeyBlocklist] componentsJoinedByString: @"\n"];
    } else if ([identifier isEqualToString: @"status"]) {
        value = [self statusForSchedule: schedule textColor: &color];
    }
    cell.textField.stringValue = value;
    cell.textField.textColor = color;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    [self updateButtons];
}

@end
