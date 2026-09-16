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

// 系统圆点替换实验：4种自定义路径变体轮换，定位渲染失败原因
%hook PSPointerClientController
- (void)setActiveHoverRegion:(id)region transitionCompletion:(id)completion {
    static int logCount = 0;
    if (logCount < 3) { PCLog(@"region update (native pipeline, client replacement disabled)"); logCount++; }
    %orig;
}
%end


%ctor {
    %init;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PCLog(@"pcpointer 1.9 loaded (complete recon)");
        // mach服务名：指针守护进程的身份
        Class specClass = objc_getClass("PSPointerClientDefaultServiceSpecification");
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
    });
}
