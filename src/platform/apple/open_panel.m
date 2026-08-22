#import <AppKit/AppKit.h>
#include "open_panel.h"
#include <string.h>

@interface ScoreAccessibilityElement : NSAccessibilityElement
@property(nonatomic) unsigned int scoreID;
@property(nonatomic) ScoreAccessibilityActivateCallback scoreCallback;
@property(nonatomic) void *scoreContext;
@end

@implementation ScoreAccessibilityElement
- (BOOL)accessibilityPerformPress {
    if (self.scoreCallback == NULL) return NO;
    self.scoreCallback(self.scoreID, self.scoreContext);
    return YES;
}
@end

const char *score_application_support_path(void) {
    static char support_path[4096];
    support_path[0] = '\0';
    @autoreleasepool {
        NSURL *root = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
        NSURL *directory = [root URLByAppendingPathComponent:@"Score" isDirectory:YES];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) return support_path;
        const char *path = directory.fileSystemRepresentation;
        if (path != NULL) {
            strncpy(support_path, path, sizeof(support_path) - 1);
            support_path[sizeof(support_path) - 1] = '\0';
        }
    }
    return support_path;
}

const char *score_open_score_panel(void) {
    static char selected_path[4096];
    selected_path[0] = '\0';
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"Import a score you are authorized to use";
        panel.message = @"MusicXML, MIDI, and Score documents are imported locally.";
        panel.canChooseDirectories = NO;
        panel.canChooseFiles = YES;
        panel.allowsMultipleSelection = NO;
        panel.allowedFileTypes = @[@"musicxml", @"xml", @"mxl", @"mid", @"midi", @"score"];
        if ([panel runModal] == NSModalResponseOK) {
            const char *path = panel.URL.fileSystemRepresentation;
            if (path != NULL) {
                strncpy(selected_path, path, sizeof(selected_path) - 1);
                selected_path[sizeof(selected_path) - 1] = '\0';
            }
        }
    }
    return selected_path;
}

const char *score_save_score_panel(void) {
    static char selected_path[4096];
    selected_path[0] = '\0';
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = @"Export a portable Score document";
        panel.message = @"The document contains notation and anchored annotations.";
        panel.nameFieldStringValue = @"score-document.score";
        panel.allowedFileTypes = @[@"score"];
        panel.canCreateDirectories = YES;
        if ([panel runModal] == NSModalResponseOK) {
            const char *path = panel.URL.fileSystemRepresentation;
            if (path != NULL) {
                strncpy(selected_path, path, sizeof(selected_path) - 1);
                selected_path[sizeof(selected_path) - 1] = '\0';
            }
        }
    }
    return selected_path;
}

void score_replay_audio_file(const char *path) {
    static NSSound *active_sound = nil;
    if (path == NULL) return;
    @autoreleasepool {
        [active_sound stop];
        active_sound = [[NSSound alloc] initWithContentsOfFile:[NSString stringWithUTF8String:path] byReference:NO];
        [active_sound play];
    }
}

void score_accessibility_update(const ScoreAccessibilityItemNative *items, unsigned int count, ScoreAccessibilityActivateCallback callback, void *context) {
    static NSData *previous_snapshot = nil;
    static NSArray *owned_elements = nil;
    if (items == NULL || count == 0) return;
    @autoreleasepool {
        NSData *snapshot = [NSData dataWithBytes:items length:sizeof(*items) * count];
        if ([snapshot isEqualToData:previous_snapshot]) return;
        previous_snapshot = snapshot;
        NSWindow *window = NSApp.keyWindow ?: NSApp.windows.firstObject;
        NSView *parent = window.contentView;
        if (parent == nil) return;
        NSMutableArray *elements = [NSMutableArray arrayWithCapacity:count];
        for (unsigned int index = 0; index < count; ++index) {
            const ScoreAccessibilityItemNative *item = &items[index];
            NSString *label = [[NSString alloc] initWithBytes:item->label length:item->label_len encoding:NSUTF8StringEncoding];
            NSAccessibilityRole role = item->role == 0 ? NSAccessibilityGroupRole : (item->role == 2 ? NSAccessibilityRadioButtonRole : NSAccessibilityButtonRole);
            ScoreAccessibilityElement *element = [ScoreAccessibilityElement accessibilityElementWithRole:role frame:NSZeroRect label:label parent:parent];
            element.scoreID = item->id;
            element.scoreCallback = callback;
            element.scoreContext = context;
            element.accessibilityEnabled = YES;
            element.accessibilityFrameInParentSpace = NSMakeRect(item->rect[0], parent.bounds.size.height - item->rect[1] - item->rect[3], item->rect[2], item->rect[3]);
            if ((item->flags & 3) != 0) element.accessibilityValue = @YES;
            [elements addObject:element];
        }
        owned_elements = [elements copy];
        parent.accessibilityRole = NSAccessibilityGroupRole;
        parent.accessibilityLabel = @"Score music studio";
        parent.accessibilityChildren = owned_elements;
    }
}
