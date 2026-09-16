#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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

%ctor {
    %init;
    BBLog(@"PCPointerBB injected into backboardd");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FILE *f = fopen("/var/mobile/pcpointer_bb.log", "a");
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
