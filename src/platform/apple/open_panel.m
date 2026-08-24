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

int score_current_work_area(int *x, int *y, int *width, int *height) {
    @autoreleasepool {
        NSScreen *screen = NSApp.keyWindow.screen ?: NSScreen.mainScreen;
        if (screen == nil) return 0;
        const NSRect visible = screen.visibleFrame;
        const CGRect mainDisplay = CGDisplayBounds(CGMainDisplayID());
        if (x != NULL) *x = (int)visible.origin.x;
        if (y != NULL) *y = (int)(mainDisplay.size.height - visible.origin.y - visible.size.height);
        if (width != NULL) *width = (int)visible.size.width;
        if (height != NULL) *height = (int)visible.size.height;
        return visible.size.width > 0 && visible.size.height > 0;
    }
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

const char *score_open_instrument_panel(void) {
    static char selected_path[4096];
    selected_path[0] = '\0';
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"Load a sampled instrument";
        panel.message = @"Choose an SFZ file. Samples remain local and the current instrument stays active if loading fails.";
        panel.canChooseDirectories = NO;
        panel.canChooseFiles = YES;
        panel.allowsMultipleSelection = NO;
        panel.allowedFileTypes = @[@"sfz"];
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
        panel.title = @"Export complete score, notation, or MIDI";
        panel.message = @"Use PDF for the complete printable score, MusicXML for notation exchange, MIDI for DAWs and instruments, or Score for a complete editable session.";
        panel.nameFieldStringValue = @"score.musicxml";
        panel.allowedFileTypes = @[@"pdf", @"musicxml", @"xml", @"mxl", @"mid", @"midi", @"score"];
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

const char *score_save_take_panel(void) {
    static char selected_path[4096];
    selected_path[0] = '\0';
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = @"Export recorded MIDI take";
        panel.message = @"Exports the captured performance timing, velocity, channels, and controller movements.";
        panel.nameFieldStringValue = @"latest-take.mid";
        panel.allowedFileTypes = @[@"mid", @"midi"];
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

void *score_pdf_begin(const char *path, double width_points, double height_points) {
    if (path == NULL) return NULL;
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        CGRect mediaBox = CGRectMake(0, 0, width_points, height_points);
        return CGPDFContextCreateWithURL((__bridge CFURLRef)url, &mediaBox, NULL);
    }
}

int score_pdf_append_bgra(void *context, const unsigned char *pixels, unsigned int width, unsigned int height, unsigned int stride) {
    if (context == NULL || pixels == NULL || width == 0 || height == 0) return 0;
    CGContextRef pdf = (CGContextRef)context;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, (size_t)stride * height, NULL);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (provider == NULL || colorSpace == NULL) {
        if (provider != NULL) CGDataProviderRelease(provider);
        if (colorSpace != NULL) CGColorSpaceRelease(colorSpace);
        return 0;
    }
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (image == NULL) return 0;
    CGRect mediaBox = CGRectMake(0, 0, 595, 842);
    CGContextBeginPage(pdf, &mediaBox);
    CGContextSaveGState(pdf);
    CGContextScaleCTM(pdf, mediaBox.size.width / width, mediaBox.size.height / height);
    CGContextDrawImage(pdf, CGRectMake(0, 0, width, height), image);
    CGContextRestoreGState(pdf);
    CGContextEndPage(pdf);
    CGImageRelease(image);
    return 1;
}

void score_pdf_end(void *context) {
    if (context == NULL) return;
    CGContextRef pdf = (CGContextRef)context;
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
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
