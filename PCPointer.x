#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>

#define PC_LOG 1 // 诊断轮

static void PCLog(NSString *msg) {
    if (!PC_LOG) return;
    FILE *f = fopen("/var/mobile/pcpointer.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[PC %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

// macOS风格箭头（尖端在原点）
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

// 系统圆点替换实验：4种自定义路径变体轮换，定位渲染失败原因
%hook PSPointerClientController
- (void)setActiveHoverRegion:(id)region transitionCompletion:(id)completion {
    @try {
        static int logCount = 0;
        if (region && [region respondsToSelector:NSSelectorFromString(@"pointerShape")]) {
            SEL shapeSel = NSSelectorFromString(@"pointerShape");
            id shape = ((id(*)(id, SEL))objc_msgSend)(region, shapeSel);
            BOOL needsReplace = NO;
            NSString *why = @"";
            if (!shape) { needsReplace = YES; why = @"nil"; }
            else if ([shape isKindOfClass:objc_getClass("PSPointerShape")]) {
                SEL pathSel = NSSelectorFromString(@"path");
                id p = [(id)shape respondsToSelector:pathSel] ? ((id(*)(id, SEL))objc_msgSend)(shape, pathSel) : nil;
                if (!p) { needsReplace = YES; why = @"circle"; }
            }
            if (needsReplace) {
                id mutable = [(id)region mutableCopy];
                SEL setSel = NSSelectorFromString(@"setPointerShape:");
                if (mutable && [mutable respondsToSelector:setSel]) {
                    Class psClass = objc_getClass("PSPointerShape");
                    SEL customSel = NSSelectorFromString(@"customShapeWithPath:");
                    SEL customSelEO = NSSelectorFromString(@"customShapeWithPath:usesEvenOddFillRule:");
                    static int variantIdx = 0;
                    int v = variantIdx % 4; variantIdx++;
                    id newShape = nil;
                    if (v == 0) {
                        // 变体0：箭头，不设pinnedPoint
                        if ([psClass respondsToSelector:customSel])
                            newShape = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, ArrowPath());
                    } else if (v == 1) {
                        // 变体1：简单三角形
                        UIBezierPath *tri = [UIBezierPath bezierPath];
                        [tri moveToPoint:CGPointMake(0, 0)];
                        [tri addLineToPoint:CGPointMake(0, 20)];
                        [tri addLineToPoint:CGPointMake(14, 10)];
                        [tri closePath];
                        if ([psClass respondsToSelector:customSel])
                            newShape = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, tri);
                    } else if (v == 2) {
                        // 变体2：箭头 + evenOdd填充
                        if ([psClass respondsToSelector:customSelEO])
                            newShape = ((id(*)(id, SEL, id, BOOL))objc_msgSend)(psClass, customSelEO, ArrowPath(), YES);
                    } else {
                        // 变体3：放大3倍箭头
                        UIBezierPath *big = [ArrowPath() copy];
                        [big applyTransform:CGAffineTransformMakeScale(3.0, 3.0)];
                        if ([psClass respondsToSelector:customSel])
                            newShape = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, big);
                    }
                    if (newShape) {
                        ((void(*)(id, SEL, id))objc_msgSend)(mutable, setSel, newShape);
                        region = mutable;
                        if (logCount < 16) { PCLog([NSString stringWithFormat:@"variant %d applied (shape=%@)", v, why]); logCount++; }
                    }
                }
            } else if (logCount < 16) {
                PCLog([NSString stringWithFormat:@"shape present (%@), pass", NSStringFromClass([shape class])]);
                logCount++;
            }
        }
    } @catch (NSException *ex) {
        PCLog([NSString stringWithFormat:@"region hook exception: %@", ex]);
    }
    %orig;
}
%end

%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PCLog(@"pcpointer 1.9 loaded (complete recon)");
        // mach服务名：指针守护进程的身份
        Class specClass = objc_getClass("PSPointerDefaultServiceSpecification");
        if (specClass) {
            SEL machSel = NSSelectorFromString(@"machName");
            SEL domSel = NSSelectorFromString(@"domainName");
            SEL svcSel = NSSelectorFromString(@"serviceName");
            FILE *sf = fopen("/var/mobile/pcpointer_mach.log", "w");
            if (sf) {
                id mn = [specClass respondsToSelector:machSel] ? ((id(*)(id, SEL))objc_msgSend)(specClass, machSel) : nil;
                id dn = [specClass respondsToSelector:domSel] ? ((id(*)(id, SEL))objc_msgSend)(specClass, domSel) : nil;
                id sn = [specClass respondsToSelector:svcSel] ? ((id(*)(id, SEL))objc_msgSend)(specClass, svcSel) : nil;
                fprintf(sf, "mach=%s domain=%s service=%s\n",
                    mn ? [(NSString*)mn UTF8String] : "?",
                    dn ? [(NSString*)dn UTF8String] : "?",
                    sn ? [(NSString*)sn UTF8String] : "?");
                fclose(sf);
                PCLog(@"mach service probed");
            }
        }
        // 按框架dump：PointerUIServices 全部类（找服务端）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FILE *f = fopen("/var/mobile/pcpointer_puis.log", "w");
            if (!f) return;
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            unsigned int hits = 0;
            for (unsigned int i = 0; i < count; i++) {
                Class c = classes[i];
                const char *imgName = class_getImageName(c);
                if (!imgName || !strstr(imgName, "PointerUI")) continue;
                hits++;
                const char *nm = class_getName(c);
                const char *slash = strrchr(imgName, '/');
                fprintf(f, "=== %s  [%s]\n", nm, slash ? slash + 1 : imgName);
                unsigned int mcount = 0;
                Method *methods = class_copyMethodList(c, &mcount);
                for (unsigned int j = 0; j < mcount && j < 50; j++)
                    fprintf(f, "    - %s\n", sel_getName(method_getName(methods[j])));
                if (methods) free(methods);
            }
            fprintf(f, "--- total: %u, PointerUI classes: %u\n", count, hits);
            free(classes);
            fclose(f);
        });
        Class specClass = objc_getClass("PSPointerDefaultServiceSpecification");
        if (specClass) {
            SEL machSel = NSSelectorFromString(@"machName");
            SEL domSel = NSSelectorFromString(@"domainName");
            if ([specClass respondsToSelector:machSel]) {
                id mn = ((id(*)(id, SEL))objc_msgSend)(specClass, machSel);
                id dn = [specClass respondsToSelector:domSel] ? ((id(*)(id, SEL))objc_msgSend)(specClass, domSel) : nil;
                FILE *sf = fopen("/var/mobile/pcpointer_mach.log", "w");
                if (sf) { fprintf(sf, "mach=%s domain=%s\n", mn ? [(NSString*)mn UTF8String] : "?", dn ? [(NSString*)dn UTF8String] : "?"); fclose(sf); }
            }
        }
    });
}
