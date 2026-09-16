#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>

// 侦察模式 v1.0.0：dump SpringBoard 中 Pointer/Cursor 相关类及其方法清单
// 产出 /var/mobile/pcpointer_recon.log 供分析绘制层，后续版本实现箭头替换

static BOOL IsTargetClass(const char *nm) {
    if (!nm) return NO;
    return strstr(nm, "Pointer") || strstr(nm, "pointer") || strstr(nm, "Cursor") || strstr(nm, "cursor");
}

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
