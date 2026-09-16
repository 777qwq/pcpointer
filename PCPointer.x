#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define PC_LOG 1

static void PCLog(NSString *msg) {
    if (!PC_LOG) return;
    FILE *f = fopen("/var/mobile/pcpointer.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[PC %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
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

// ivar手术：修复 customShapeWithPath 的 inf/zero bounds bug
static void FixShapeBounds(id shape) {
    @try {
        unsigned int icount = 0;
        Ivar *ivars = class_copyIvarList([shape class], &icount);
        for (unsigned int i = 0; i < icount; i++) {
            const char *nm = ivar_getName(ivars[i]);
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (!enc) continue;
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            char *base = (char *)(__bridge void *)shape;
            if (strstr(enc, "CGRect") == enc) {
                CGRect *r = (CGRect *)(base + off);
                PCLog([NSString stringWithFormat:@"ivar %s(CGRect) was %@ -> fix", nm ? nm : "?", NSStringFromCGRect(*r)]);
                *r = CGRectMake(0, 0, 14, 22);
            } else if (strstr(enc, "CGSize") == enc) {
                CGSize *s = (CGSize *)(base + off);
                PCLog([NSString stringWithFormat:@"ivar %s(CGSize) was %@ -> fix", nm ? nm : "?", NSStringFromCGSize(*s)]);
                *s = CGSizeMake(14, 22);
            } else if (enc[0] == 'd' || enc[0] == 'f') {
                double *d = (double *)(base + off);
                if (*d > 1e100 || (*d != *d)) { // inf/nan
                    PCLog([NSString stringWithFormat:@"ivar %s(double) was inf/nan -> fix 0", nm ? nm : "?"]);
                    *d = 0.0;
                }
            }
        }
        if (ivars) free(ivars);
        // 验证
        SEL boundsSel = NSSelectorFromString(@"bounds");
        SEL sizeSel = NSSelectorFromString(@"size");
        if ([shape respondsToSelector:boundsSel]) {
            CGRect b = ((CGRect(*)(id, SEL))objc_msgSend)(shape, boundsSel);
            PCLog([NSString stringWithFormat:@"after surgery bounds=%@", NSStringFromCGRect(b)]);
        }
        if ([shape respondsToSelector:sizeSel]) {
            CGSize s = ((CGSize(*)(id, SEL))objc_msgSend)(shape, sizeSel);
            PCLog([NSString stringWithFormat:@"after surgery size=%@", NSStringFromCGSize(s)]);
        }
    } @catch (NSException *ex) {
        PCLog([NSString stringWithFormat:@"surgery exception: %@", ex]);
    }
}

static id MakeFixedArrowShape(void) {
    Class psClass = objc_getClass("PSPointerShape");
    if (!psClass) return nil;
    SEL customSel = NSSelectorFromString(@"customShapeWithPath:");
    if (![psClass respondsToSelector:customSel]) return nil;
    id shape = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, ArrowPath());
    if (!shape) return nil;
    FixShapeBounds(shape);
    SEL pinSel = NSSelectorFromString(@"setPinnedPoint:");
    if ([shape respondsToSelector:pinSel]) {
        ((void(*)(id, SEL, CGPoint))objc_msgSend)(shape, pinSel, CGPointMake(0, 0));
    }
    return shape;
}

// 系统圆点（无路径形状）→ 修复bounds后的箭头
%hook PSPointerClientController
- (void)setActiveHoverRegion:(id)region transitionCompletion:(id)completion {
    @try {
        static int logCount = 0;
        if (region && [region respondsToSelector:NSSelectorFromString(@"pointerShape")]) {
            SEL shapeSel = NSSelectorFromString(@"pointerShape");
            id shape = ((id(*)(id, SEL))objc_msgSend)(region, shapeSel);
            BOOL needsReplace = NO;
            if (!shape) needsReplace = YES;
            else if ([shape isKindOfClass:objc_getClass("PSPointerShape")]) {
                SEL pathSel = NSSelectorFromString(@"path");
                id p = [(id)shape respondsToSelector:pathSel] ? ((id(*)(id, SEL))objc_msgSend)(shape, pathSel) : nil;
                if (!p) needsReplace = YES;
            }
            if (needsReplace) {
                id mutable = [(id)region mutableCopy];
                SEL setSel = NSSelectorFromString(@"setPointerShape:");
                if (mutable && [mutable respondsToSelector:setSel]) {
                    id arrow = MakeFixedArrowShape();
                    if (arrow) {
                        ((void(*)(id, SEL, id))objc_msgSend)(mutable, setSel, arrow);
                        region = mutable;
                        if (logCount < 6) { PCLog(@"dot -> arrow (bounds fixed)"); logCount++; }
                    }
                }
            }
        }
    } @catch (NSException *ex) {
        PCLog([NSString stringWithFormat:@"region exception: %@", ex]);
    }
    %orig;
}
%end

%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PCLog(@"pcpointer 2.6 loaded (bounds surgery)");
    });
}
