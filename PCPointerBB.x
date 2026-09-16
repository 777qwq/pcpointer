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
    id shape = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, ArrowPath());
    if (!shape) return nil;
    // bounds手术（ivar直写）
    unsigned int icount = 0;
    Ivar *ivars = class_copyIvarList(psClass, &icount);
    for (unsigned int i = 0; i < icount; i++) {
        const char *nm = ivar_getName(ivars[i]) ?: "?";
        const char *enc = ivar_getTypeEncoding(ivars[i]) ?: "";
        if (strstr(nm, "_bounds") && strstr(enc, "CGRect")) {
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            CGRect *r = (CGRect *)((char *)(__bridge void *)shape + off);
            PCLog(@"[daemon] fixing _bounds");
            *r = CGRectMake(0, 0, 14, 22);
        }
    }
    if (ivars) free(ivars);
    SEL pinSel = NSSelectorFromString(@"setPinnedPoint:");
    if ([shape respondsToSelector:pinSel]) {
        ((void(*)(id, SEL, CGPoint))objc_msgSend)(shape, pinSel, CGPointMake(0, 0));
    }
    return shape;
}

%hook PSPointerShape
+ (id)systemShape {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l1 = NO;
        if (!l1) { BBLog(@"systemShape -> arrow hijacked"); l1 = YES; }
        return arrow;
    }
    return %orig;
}
+ (id)circleWithSize:(CGFloat)size {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l2 = NO;
        if (!l2) { BBLog(@"circleWithSize -> arrow hijacked"); l2 = YES; }
        return arrow;
    }
    return %orig;
}
+ (id)circleWithBounds:(CGRect)bounds {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l3 = NO;
        if (!l3) { BBLog(@"circleWithBounds -> arrow hijacked"); l3 = YES; }
        return arrow;
    }
    return %orig;
}
%end

%ctor {
    %init;
    BBLog([NSString stringWithFormat:@"PCPointerBB injected into %@", [NSProcessInfo.processInfo processName]]);
}
