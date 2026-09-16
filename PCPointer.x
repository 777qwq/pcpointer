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

// blob字节手术：定位形状内部编码数据，替换 inf/零 尺寸字段
static void FixShapeBounds(id shape) {
    @try {
        unsigned int icount = 0;
        Ivar *ivars = class_copyIvarList([shape class], &icount);
        PCLog([NSString stringWithFormat:@"ivar count=%u", icount]);
        for (unsigned int i = 0; i < icount; i++) {
            const char *nm = ivar_getName(ivars[i]) ?: "?";
            const char *enc = ivar_getTypeEncoding(ivars[i]) ?: "?";
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            PCLog([NSString stringWithFormat:@"ivar %s enc=%s off=%d", nm, enc, (int)off]);
            if (enc[0] == '@') {
                id obj = object_getIvar(shape, ivars[i]);
                if ([obj isKindOfClass:[NSData class]]) {
                    NSMutableData *md = [obj mutableCopy];
                    if (md.length > 32) {
                        unsigned char *bytes = (unsigned char *)md.bytes;
                        unsigned long len = md.length;
                        // 搜索连续两个 +inf (00 00 00 00 00 00 F0 7F x2)
                        int replaced = 0;
                        for (unsigned long k = 0; k + 16 <= len; k++) {
                            if (bytes[k] == 0x00 && bytes[k+1] == 0x00 && bytes[k+2] == 0x00 &&
                                bytes[k+3] == 0x00 && bytes[k+4] == 0x00 && bytes[k+5] == 0x00 &&
                                bytes[k+6] == 0xF0 && bytes[k+7] == 0x7F &&
                                bytes[k+8] == 0x00 && bytes[k+9] == 0x00 && bytes[k+10] == 0x00 &&
                                bytes[k+11] == 0x00 && bytes[k+12] == 0x00 && bytes[k+13] == 0x00 &&
                                bytes[k+14] == 0xF0 && bytes[k+15] == 0x7F) {
                                double zero = 0.0, w = 14.0, h = 22.0;
                                memcpy(bytes + k, &zero, 8);
                                memcpy(bytes + k + 8, &zero, 8);
                                memcpy(bytes + k + 16, &w, 8);
                                memcpy(bytes + k + 24, &h, 8);
                                replaced++;
                                k += 31;
                            }
                        }
                        PCLog([NSString stringWithFormat:@"NSData ivar %s: %lu bytes, %d inf-pairs patched", nm, len, replaced]);
                        if (replaced > 0) {
                            object_setIvar(shape, ivars[i], md);
                        }
                    } else {
                        PCLog([NSString stringWithFormat:@"NSData ivar %s too small (%lu)", nm, (unsigned long)md.length]);
                    }
                }
            }
        }
        if (ivars) free(ivars);
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
