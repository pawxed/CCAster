#import <CoreFoundation/CoreFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CFNetwork/CFNetwork.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Lightweight, performance-first rewrite of the original Tweak.xm
// Goals: remove massive global state, avoid repeated deep view-tree traversals,
// throttle/limit any scheduled work, and keep the public surface small so the
// tweak remains responsive on older runtime environments.

static CFStringRef const kCCAPrefsDomain = CFSTR("com.futur3sn0w.ccaster.preferences");
static NSString *const kCCAReloadNotification = @"com.futur3sn0w.ccaster/ReloadPrefs";

// Small configuration structure rather than many globals. Update atomically.
typedef struct {
    BOOL enabled;
    BOOL quickAccessButtonsEnabled;
    BOOL pagingEnabled;
    BOOL blankSpaceGestureEnabled;
    BOOL addButtonEnabled;
    BOOL powerButtonEnabled;
    BOOL removalButtonsEnabled;
    BOOL moduleBordersEnabled;
    BOOL borderBreathingEnabled;
    BOOL hapticsEnabled;
} CCAConfig;

static CCAConfig gConfig = { .enabled = YES,
    .quickAccessButtonsEnabled = YES,
    .pagingEnabled = YES,
    .blankSpaceGestureEnabled = YES,
    .addButtonEnabled = YES,
    .powerButtonEnabled = YES,
    .removalButtonsEnabled = YES,
    .moduleBordersEnabled = YES,
    .borderBreathingEnabled = YES,
    .hapticsEnabled = YES
};

// Replace many fine-grained globals with a single small runtime state object.
@interface CCAState : NSObject
@property (nonatomic) BOOL editModeActive;
@property (nonatomic) BOOL expandedModuleOpen;
@property (nonatomic, strong) NSHashTable<UIViewController *> *overlayControllers;
@property (nonatomic) NSUInteger currentPage;
@property (nonatomic) NSUInteger pageCount;
@property (nonatomic, strong) NSTimer *debounceTimer;
@end

@implementation CCAState
+ (instancetype)shared {
    static CCAState *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [CCAState new]; s.overlayControllers = [NSHashTable weakObjectsHashTable]; s.currentPage = 0; s.pageCount = 1; });
    return s;
}
@end

// Simple, low-cost blur view that avoids CoreImage work on layout calls.
@interface CCALowBlurView : UIView
@end

@implementation CCALowBlurView
+ (Class)layerClass { return CALayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    // Use a very light, static effect to avoid per-frame filter changes.
    self.layer.backgroundColor = [[UIColor colorWithWhite:1.0 alpha:0.02] CGColor];
    self.layer.cornerRadius = 0.0;
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; /* no expensive work here */ }
@end

// Top fade view that uses a CAGradientLayer but avoids updating it repeatedly.
@interface CCATopFadeView : UIView
@end

@implementation CCATopFadeView {
    CAGradientLayer *_maskLayer;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO; self.backgroundColor = UIColor.clearColor; self.opaque = NO;
    _maskLayer = [CAGradientLayer layer];
    _maskLayer.colors = @[ (__bridge id)[UIColor colorWithWhite:0 alpha:0.6].CGColor, (__bridge id)[UIColor clearColor].CGColor ];
    _maskLayer.startPoint = CGPointMake(0.5, 0.0); _maskLayer.endPoint = CGPointMake(0.5, 1.0);
    self.layer.mask = _maskLayer;
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; _maskLayer.frame = self.bounds; }
@end

// Lightweight grid view used for edit mode. Avoid per-frame allocations and
// expensive CoreAnimation transactions on updates.
@interface CCAEditGridView : UIView
@property (nonatomic, copy) NSArray<NSValue *> *slotRects;
@property (nonatomic, copy) NSArray<NSValue *> *occupiedRects;
@property (nonatomic) CAShapeLayer *cellsLayer; // draws all cells at once
@end

@implementation CCAEditGridView
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor; self.userInteractionEnabled = NO; self.opaque = NO;
    _cellsLayer = [CAShapeLayer layer]; _cellsLayer.fillColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor; _cellsLayer.opacity = 1.0;
    [self.layer addSublayer:_cellsLayer];
    return self;
}
- (void)layoutSubviews { [super layoutSubviews]; _cellsLayer.frame = self.bounds; [self updateCellsPath]; }
- (void)setSlotRects:(NSArray<NSValue *> *)slotRects { _slotRects = [slotRects copy]; [self setNeedsLayout]; }
- (void)setOccupiedRects:(NSArray<NSValue *> *)occupiedRects { _occupiedRects = [occupiedRects copy]; [self setNeedsLayout]; }
- (void)updateCellsPath {
    if (!self.slotRects.count) { _cellsLayer.path = nil; return; }
    UIBezierPath *combined = [UIBezierPath bezierPath];
    for (NSValue *v in self.slotRects) {
        CGRect r = v.CGRectValue;
        // Skip cells that intersect occupied rects to reduce draw work
        BOOL occupied = NO;
        for (NSValue *ov in self.occupiedRects) { if (CGRectIntersectsRect(r, ov.CGRectValue)) { occupied = YES; break; } }
        if (occupied) continue;
        CGFloat diameter = MIN(CGRectGetWidth(r), CGRectGetHeight(r)) * 0.92;
        CGRect circle = CGRectMake(CGRectGetMidX(r) - diameter * 0.5, CGRectGetMidY(r) - diameter * 0.5, diameter, diameter);
        [combined appendPath:[UIBezierPath bezierPathWithOvalInRect:circle]];
    }
    _cellsLayer.path = combined.CGPath;
}
@end

// Utility: bounded, shallow search for a pan recognizer. Limits work to avoid
// traversing the entire view tree every time.
static UIPanGestureRecognizer *CCAFindActiveControlCenterPresentationPan(UIView *root) {
    if (!root) return nil;
    // breadth-first up to a small cap
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    const NSUInteger kMaxVisited = 200; NSUInteger visited = 0;
    while (queue.count && visited < kMaxVisited) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0]; visited++;
        NSArray *grs = v.gestureRecognizers; if (grs) {
            for (UIGestureRecognizer *g in grs) {
                if (![g isKindOfClass:[UIPanGestureRecognizer class]]) continue;
                UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)g;
                if (pan.numberOfTouches == 0) continue;
                // only accept gestures that are active-ish
                if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) return pan;
            }
        }
        // add subviews but keep queue short
        if (v.subviews.count) {
            for (NSUInteger i = 0; i < v.subviews.count && queue.count < kMaxVisited; i++) [queue addObject:v.subviews[i]];
        }
    }
    return nil;
}

// Debounced, single-scheduled update helper to replace repeated dispatch_after
static void CCAScheduleDebouncedUpdate(void (^block)(void), NSTimeInterval delay) {
    CCAState *s = [CCAState shared];
    if (!block) return;
    [s.debounceTimer invalidate];
    s.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:delay target:[NSBlockOperation blockOperationWithBlock:block] selector:@selector(main) userInfo:nil repeats:NO];
}

// Lightweight clamp for a single scroll view. Avoid walking other scroll views.
static void CCAClampSingleScrollView(UIScrollView *scrollView) {
    if (!scrollView) return;
    // minimal adjustments only; do not mutate contentSize aggressively.
    scrollView.alwaysBounceVertical = NO;
    scrollView.alwaysBounceHorizontal = NO;
    scrollView.bounces = NO;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    UIEdgeInsets inset = scrollView.contentInset;
    if (inset.top < 0) inset.top = 0; // guard against odd values
    scrollView.contentInset = inset;
    // clamp contentOffset to reasonable range
    CGPoint offset = scrollView.contentOffset;
    offset.x = MAX(0, MIN(offset.x, scrollView.contentSize.width - scrollView.bounds.size.width));
    offset.y = MAX(0, MIN(offset.y, scrollView.contentSize.height - scrollView.bounds.size.height));
    if (!CGPointEqualToPoint(offset, scrollView.contentOffset)) [scrollView setContentOffset:offset animated:NO];
}

// Public API hooks (small, safe wrappers that other parts of the tweak can call)
static void CCARegisterOverlayController(UIViewController *controller) {
    if (!controller) return;
    @synchronized ([CCAState shared]) { [[CCAState shared].overlayControllers addObject:controller]; }
}

static void CCAUnregisterOverlayController(UIViewController *controller) {
    if (!controller) return;
    @synchronized ([CCAState shared]) { [[CCAState shared].overlayControllers removeObject:controller]; }
}

// Example: fast reassert of scroll clamp across registered overlays, debounced
static void CCAReassertNativeScrollClampForRegisteredOverlays(void) {
    // schedule once per frame-equivalent but debounced to 16ms at most
    CCAScheduleDebouncedUpdate(^{
        NSHashTable *table = [CCAState shared].overlayControllers;
        for (UIViewController *overlay in table) {
            @try {
                id sv = nil;
                if ([overlay respondsToSelector:NSSelectorFromString(@"overlayScrollView")]) {
                    sv = [overlay valueForKey:@"overlayScrollView"];
                }
                if ([sv isKindOfClass:[UIScrollView class]]) CCAClampSingleScrollView((UIScrollView *)sv);
            } @catch (__unused NSException *e) { continue; }
        }
    }, 0.016);
}

// Small helpers used by UI components
static CGRect CCARemoveButtonFrameForModuleFrame(CGRect moduleFrame) {
    const CGFloat kRemoveHitSize = 44.0; const CGFloat kRemoveVisualCenterOffset = 8.0;
    CGFloat originOffset = kRemoveVisualCenterOffset - kRemoveHitSize * 0.5;
    return CGRectMake(CGRectGetMinX(moduleFrame) + originOffset,
                      CGRectGetMinY(moduleFrame) + originOffset,
                      kRemoveHitSize, kRemoveHitSize);
}

// Keep the file minimal. Additional features and compatibility layers can be
// reintroduced in small, well-tested patches that avoid broad, synchronous
// traversal or per-frame work.

// Logos hooks and other runtime method swizzles should be implemented in
// separate small patches that call the helpers above. This file focuses on
// providing a faster runtime foundation.

