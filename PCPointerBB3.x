#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static void BBLog(NSString *msg) {
    FILE *f = fopen("/var/mobile/pcpointer_bb.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[BB %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

// macOS风格箭头（尖端原点）——在pointeruid进程内创建，不过XPC，直接渲染
static UIBezierPath *ArrowPath(void) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, 0)];
    [p addLineToPoint:CGPointMake(0, 16.9)];
    [p addLineToPoint:CGPointMake(4.2, 12.9)];
    [p addLineToPoint:CGPointMake(6.7, 18.7)];
    [p addLineToPoint:CGPointMake(9.3, 17.6)];
    [p addLineToPoint:CGPointMake(6.8, 12.0)];
    [p addLineToPoint:CGPointMake(11.8, 11.6)];
    [p closePath];
    return p;
}

static id MakeArrowShape(Class psClass) {
    SEL customSel = NSSelectorFromString(@"customShapeWithPath:");
    if (![psClass respondsToSelector:customSel]) return nil;
    id arrow = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, ArrowPath());
    if (arrow) {
        SEL pinSel = NSSelectorFromString(@"setPinnedPoint:");
        if ([arrow respondsToSelector:pinSel]) {
            ((void(*)(id, SEL, CGPoint))objc_msgSend)(arrow, pinSel, CGPointMake(0, 0));
        }
    }
    return arrow;
}

%hook PSPointerShape
+ (id)systemShape {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l1 = NO;
        if (!l1) { BBLog(@"systemShape -> arrow (daemon-side hijack)"); l1 = YES; }
        return arrow;
    }
    return %orig;
}
+ (id)circleWithSize:(CGFloat)size {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l2 = NO;
        if (!l2) { BBLog(@"circleWithSize -> arrow (daemon-side)"); l2 = YES; }
        return arrow;
    }
    return %orig;
}
+ (id)circleWithBounds:(CGRect)bounds {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l3 = NO;
        if (!l3) { BBLog(@"circleWithBounds -> arrow (daemon-side)"); l3 = YES; }
        return arrow;
    }
    return %orig;
}
%end

%ctor {
    %init;
    BBLog(@"PCPointerBB3 injected via Bundles into pointeruid (daemon-side arrow ready)");
}
