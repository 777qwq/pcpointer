#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>

#define PC_LOG 1 // 诊断轮

static void PCLog(NSString *msg) {
    if (!PC_LOG) return;
    FILE *f = fopen("/var/mobile/pcpointer.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[PC %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

// macOS风格箭头路径（尖端在原点，高约20pt）
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

// backboardd 侦察：dump 指针服务端类结构（空闲圆点的真正绘制方）
static void StartBackboardRecon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FILE *f = fopen("/var/mobile/pcpointer_bb.log", "w");
        if (!f) return;
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        unsigned int hits = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *nm = class_getName(c);
            if (!nm) continue;
            if (strstr(nm, "Pointer") || strstr(nm, "Hover") || strstr(nm, "Shape")) {
                hits++;
                const char *imgName = class_getImageName(c);
                const char *img = "unknown";
                if (imgName) { const char *slash = strrchr(imgName, '/'); img = slash ? slash + 1 : imgName; }
                fprintf(f, "=== %s  [%s]\n", nm, img);
                unsigned int mcount = 0;
                Method *methods = class_copyMethodList(c, &mcount);
                for (unsigned int j = 0; j < mcount && j < 60; j++)
                    fprintf(f, "    - %s\n", sel_getName(method_getName(methods[j])));
                if (methods) free(methods);
                Class meta = object_getClass(c);
                if (meta) {
                    mcount = 0;
                    methods = class_copyMethodList(meta, &mcount);
                    for (unsigned int j = 0; j < mcount && j < 40; j++)
                        fprintf(f, "    + %s\n", sel_getName(method_getName(methods[j])));
                    if (methods) free(methods);
                }
            }
        }
        fprintf(f, "--- total: %u, hits: %u\n", count, hits);
        free(classes);
        fclose(f);
    });
}

// A/B实验 v1.4.0：用官方roundedRect方块测试形状管线是否生效
static id SquareShape(id psClass) {
    SEL sel = NSSelectorFromString(@"roundedRectWithSize:cornerRadius:");
    if ([psClass respondsToSelector:sel]) {
        return ((id(*)(id, SEL, CGFloat, CGFloat))objc_msgSend)(psClass, sel, (CGFloat)30.0, (CGFloat)2.0);
    }
    return nil;
}

// 侦察模式 v1.0.0：dump SpringBoard 中 Pointer/Cursor 相关类及其方法清单
// 产出 /var/mobile/pcpointer_recon.log 供分析绘制层，后续版本实现箭头替换

static BOOL IsTargetClass(const char *nm) {
    if (!nm) return NO;
    return strstr(nm, "Pointer") || strstr(nm, "pointer") || strstr(nm, "Cursor") || strstr(nm, "cursor");
}

%hook _UIPointerArbiterCore_iOS
// 圆点形状 → 箭头形状（系统级单点拦截）
- (id)_psPointerShapeFromUIPointerShape:(id)uiShape atScale:(CGFloat)scale {
    id ps = %orig;
    @try {
        if (ps && [ps isKindOfClass:objc_getClass("PSPointerShape")]) {
            id existing = nil;
            if ([ps respondsToSelector:@selector(path)]) existing = [(id)ps path];
            if (!existing) { // 无自定义路径 = 系统圆点 → 替换为箭头
                Class psClass = objc_getClass("PSPointerShape");
                id arrow = nil;
                SEL customSel = NSSelectorFromString(@"customShapeWithPath:");
                if ([psClass respondsToSelector:customSel]) {
                    arrow = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, ArrowPath());
                }
                if (arrow) {
                    SEL pinSel = NSSelectorFromString(@"setPinnedPoint:");
                    if ([arrow respondsToSelector:pinSel]) {
                        ((void(*)(id, SEL, CGPoint))objc_msgSend)(arrow, pinSel, CGPointMake(0, 0));
                    }
                    static BOOL logged = NO;
                    if (!logged) { PCLog(@"dot -> arrow replaced"); logged = YES; }
                    return arrow;
                }
            }
        }
    } @catch (NSException *ex) {
        PCLog([NSString stringWithFormat:@"hook exception: %@", ex]);
    }
    return ps;
}
%end

%hook PSPointerClientController
// 系统默认圆点走这里：region.pointerShape 为空/圆 → 强制箭头
- (void)setActiveHoverRegion:(id)region transitionCompletion:(id)completion {
    @try {
        static int logCount = 0;
        if (region && [region respondsToSelector:@selector(pointerShape)]) {
            id shape = nil;
            SEL shapeSel = NSSelectorFromString(@"pointerShape");
            if ([region respondsToSelector:shapeSel]) {
                shape = ((id(*)(id, SEL))objc_msgSend)(region, shapeSel);
            }
            BOOL needsReplace = NO;
            NSString *why = @"";
            if (!shape) { needsReplace = YES; why = @"nil"; }
            else if ([shape isKindOfClass:objc_getClass("PSPointerShape")]) {
                id p = [(id)shape respondsToSelector:@selector(path)] ? [(id)shape path] : nil;
                if (!p) { needsReplace = YES; why = @"circle"; }
            }
            if (needsReplace) {
                id mutable = [(id)region respondsToSelector:@selector(mutableCopy)] ? [(id)region mutableCopy] : nil;
                SEL setSel = NSSelectorFromString(@"setPointerShape:");
                if (mutable && [mutable respondsToSelector:setSel]) {
                    Class psClass = objc_getClass("PSPointerShape");
                    SEL customSel = NSSelectorFromString(@"customShapeWithPath:");
                    id newShape = nil;
                    if ([psClass respondsToSelector:customSel]) {
                        newShape = ((id(*)(id, SEL, id))objc_msgSend)(psClass, customSel, ArrowPath());
                    }
                    if (newShape) {
                        SEL pinSel = NSSelectorFromString(@"setPinnedPoint:");
                        if ([newShape respondsToSelector:pinSel]) {
                            ((void(*)(id, SEL, CGPoint))objc_msgSend)(newShape, pinSel, CGPointMake(0, 0));
                        }
                        ((void(*)(id, SEL, id))objc_msgSend)(mutable, setSel, newShape);
                        region = mutable;
                        if (logCount < 5) { PCLog([NSString stringWithFormat:@"shape(%@) -> arrow replaced", why]); logCount++; }
                    }
                }
            } else if (logCount < 3) {
                PCLog([NSString stringWithFormat:@"shape present (%@), pass through", NSStringFromClass([shape class])]);
                logCount++;
            }
        }
    } @catch (NSException *ex) {
        PCLog([NSString stringWithFormat:@"region hook exception: %@", ex]);
    }
    %orig;
}
%end

// 空闲圆点 = 守护进程默认形状（systemShape/circle工厂）。在守护进程进程内hook工厂本身。
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
        if (!l1) { PCLog(@"systemShape -> arrow (default dot hijacked)"); l1 = YES; }
        return arrow;
    }
    return %orig;
}
+ (id)circleWithSize:(CGFloat)size {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l2 = NO;
        if (!l2) { PCLog(@"circleWithSize -> arrow"); l2 = YES; }
        return arrow;
    }
    return %orig;
}
+ (id)circleWithBounds:(CGRect)bounds {
    id arrow = MakeArrowShape(self);
    if (arrow) {
        static BOOL l3 = NO;
        if (!l3) { PCLog(@"circleWithBounds -> arrow"); l3 = YES; }
        return arrow;
    }
    return %orig;
}
%end

%ctor {
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.backboardd"]) { StartBackboardRecon(); return; }
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 探测指针服务 mach 服务名
        Class specClass = objc_getClass("PSPointerDefaultServiceSpecification");
        if (specClass) {
            SEL machSel = NSSelectorFromString(@"machName");
            SEL domSel = NSSelectorFromString(@"domainName");
            if ([specClass respondsToSelector:machSel]) {
                id mn = ((id(*)(id, SEL))objc_msgSend)(specClass, machSel);
                id dn = [specClass respondsToSelector:domSel] ? ((id(*)(id, SEL))objc_msgSend)(specClass, domSel) : nil;
                FILE *sf = fopen("/var/mobile/pcpointer_recon.log", "a");
                if (sf) { fprintf(sf, "=== mach service: %s / domain: %s\n", mn ? [(NSString*)mn UTF8String] : "?", dn ? [(NSString*)dn UTF8String] : "?"); fclose(sf); }
            }
        }
        FILE *f = fopen("/var/mobile/pcpointer_recon.log", "w");
        if (!f) return;
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        unsigned int hits = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *nm = class_getName(c);
            if (!IsTargetClass(nm)) continue;
            hits++;
            // 类所在框架
            const char *img = "unknown";
            const char *imgName = class_getImageName(c);
            if (imgName) {
                const char *slash = strrchr(imgName, '/');
                img = slash ? slash + 1 : imgName;
            }
            fprintf(f, "=== %s  [%s]\n", nm, img);
            // 实例方法（最多80个）
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(c, &mcount);
            for (unsigned int j = 0; j < mcount && j < 80; j++) {
                fprintf(f, "    - %s\n", sel_getName(method_getName(methods[j])));
            }
            if (methods) free(methods);
            // 类方法（最多40个）
            Class meta = object_getClass(c);
            if (meta) {
                mcount = 0;
                methods = class_copyMethodList(meta, &mcount);
                for (unsigned int j = 0; j < mcount && j < 40; j++) {
                    fprintf(f, "    + %s\n", sel_getName(method_getName(methods[j])));
                }
                if (methods) free(methods);
            }
        }
        fprintf(f, "--- total: %u, hits: %u\n", count, hits);
        free(classes);
        fclose(f);
    });
}
