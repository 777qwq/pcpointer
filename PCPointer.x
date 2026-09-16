#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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
                if ([psClass respondsToSelector:@selector(customShapeWithPath:)]) {
                    arrow = [psClass customShapeWithPath:ArrowPath()];
                }
                if (arrow) {
                    if ([arrow respondsToSelector:@selector(setPinnedPoint:)])
                        [arrow setPinnedPoint:CGPointMake(0, 0)];
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

%ctor {
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
