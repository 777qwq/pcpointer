#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define PC_LOG 1 // 诊断轮

static void PCLog(NSString *msg) {
    if (!PC_LOG) return;
    FILE *f = fopen("/var/mobile/pcpointer.log", "a");
    if (!f) return;
    time_t t = time(NULL); struct tm tmv; localtime_r(&t, &tmv);
    fprintf(f, "[PC %02d:%02d:%02d] %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, msg.UTF8String);
    fclose(f);
}

// ---------- 自绘箭头（白底黑边，PC风格） ----------
static UIBezierPath *ArrowPath(void) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(1, 1)];
    [p addLineToPoint:CGPointMake(1, 17.5)];
    [p addLineToPoint:CGPointMake(5.2, 13.6)];
    [p addLineToPoint:CGPointMake(7.8, 19.6)];
    [p addLineToPoint:CGPointMake(10.2, 18.5)];
    [p addLineToPoint:CGPointMake(7.6, 12.6)];
    [p addLineToPoint:CGPointMake(12.6, 12.2)];
    [p closePath];
    return p;
}

static UIWindow *g_window = nil;
static UIView *g_arrowView = nil;

static void EnsureOverlay(void) {
    if (g_window) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) { PCLog(@"no window scene yet"); return; }
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds;
    w.windowLevel = 10000000.0; // 最高层：盖过一切内容
    w.userInteractionEnabled = NO; // 触摸穿透
    w.backgroundColor = [UIColor clearColor];

    UIView *arrow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 22)];
    arrow.userInteractionEnabled = NO;
    CAShapeLayer *sl = [CAShapeLayer layer];
    sl.frame = arrow.bounds;
    sl.path = ArrowPath().CGPath;
    sl.fillColor = [UIColor whiteColor].CGColor;
    sl.strokeColor = [UIColor blackColor].CGColor;
    sl.lineWidth = 1.2;
    sl.shadowColor = [UIColor blackColor].CGColor;
    sl.shadowOpacity = 0.35;
    sl.shadowRadius = 2.0;
    sl.shadowOffset = CGSizeMake(1.0, 1.0);
    sl.zPosition = 1000;
    [arrow.layer addSublayer:sl];
    [w addSubview:arrow];

    w.hidden = NO;
    g_window = w;
    g_arrowView = arrow;
    PCLog(@"overlay arrow ready");
}

// ---------- 指针位置轮询 ----------
static CGPoint LastPointerPos(BOOL *ok) {
    *ok = NO;
    Class cls = objc_getClass("BKSMousePointerService");
    if (!cls) return CGPointZero;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:shared]) return CGPointZero;
    id svc = ((id(*)(id, SEL))objc_msgSend)(cls, shared);
    SEL posSel = NSSelectorFromString(@"globalPointerPosition");
    if (!svc || ![svc respondsToSelector:posSel]) return CGPointZero;
    CGPoint p = ((CGPoint(*)(id, SEL))objc_msgSend)(svc, posSel);
    *ok = YES;
    return p;
}

@interface PCPoller : NSObject
+ (void)start;
@end

@implementation PCPoller
+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            EnsureOverlay();
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:[PCPoller class] selector:@selector(tick)];
            link.preferredFramesPerSecond = 60;
            [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            PCLog(@"polling started");
        });
    });
}
+ (void)tick {
    static CGPoint last = { -999.0, -999.0 };
    BOOL ok = NO;
    CGPoint p = LastPointerPos(&ok);
    if (!ok) return;
    if (p.x == last.x && p.y == last.y) return;
    last = p;
    if (g_arrowView) {
        g_arrowView.frame = CGRectMake(p.x, p.y, 14, 22);
    }
}
@end

// ---------- 捕获指针客户端控制器 → 隐藏原生圆点 ----------
static id g_pcc = nil;
static BOOL g_hideRequested = NO;

%hook PSPointerClientController
- (void)setActiveHoverRegion:(id)region transitionCompletion:(id)completion {
    if (!g_pcc) {
        g_pcc = self;
        PCLog(@"pointer client controller captured");
    }
    if (!g_hideRequested && g_pcc) {
        g_hideRequested = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SEL hideSel = NSSelectorFromString(@"persistentlyHidePointerAssertionForReason:");
            if ([g_pcc respondsToSelector:hideSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(g_pcc, hideSel, @"PCPointer");
                PCLog(@"native pointer hidden via assertion");
            } else {
                PCLog(@"hide selector missing!");
            }
            [PCPoller start];
        });
    }
    %orig;
}
%end

%ctor {
    %init;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PCLog(@"pcpointer 2.0 loaded");
    });
}
