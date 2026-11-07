// IOSGridView: home feed as a grid with two videos per row.
// - Video entries on Home are measured at half width.
// - The home list's layout is replaced per instance by a subclass that places
//   videos side by side in pairs; everything else stays full width.
// - Tiles: ⋮ inside the thumbnail, title across the full width, below it a small
//   channel avatar with the channel name and a line with views and age.
// - Preview playback advances in reading order (left, right, next row).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <YouTubeHeader/YTSettingsCell.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>

@interface YTInnerTubeCollectionViewController : UIViewController
- (NSString *)browseID;
- (UICollectionView *)collectionView;
- (UICollectionViewLayout *)collectionViewLayout;
@end

@interface YTIElementRenderer : NSObject
- (NSData *)elementData;
@end

@interface YTSectionController : NSObject
- (id)sectionControllerDelegate;
@end

static NSString *const kHome = @"FEwhat_to_watch";
static const NSUInteger kColumns = 2;
static const CGFloat kGap = 8, kMargin = 8, kRowGap = 6;
// Each tile ends with an empty area (YouTube's placeholder); the next row is pulled
// up over it so that the spacing between rows is roughly halved
static const CGFloat kRowOverlap = 14;

static BOOL GVIsHome(id vc) {
    if (![vc isKindOfClass:objc_getClass("YTInnerTubeCollectionViewController")]) return NO;
    return [[vc browseID] isEqualToString:kHome];
}

#pragma mark - Which entries go into the grid?

// The element type appears as plain text in the serialized element data;
// a byte search is cheap (building the proto descriptor would be expensive)
static BOOL GVIsGridEntry(id entry) {
    if (![entry respondsToSelector:@selector(elementData)]) return NO;
    NSData *data = [entry elementData];
    static NSData *needle; static dispatch_once_t once;
    dispatch_once(&once, ^{ needle = [@"video_lockup" dataUsingEncoding:NSUTF8StringEncoding]; });
    NSRange head = NSMakeRange(0, MIN(data.length, (NSUInteger)4096));
    return [data rangeOfData:needle options:0 range:head].location != NSNotFound;
}

static CGFloat GVColumnWidth(CGFloat containerWidth) {
    return floor((containerWidth - 2 * kMargin - (kColumns - 1) * kGap) / kColumns);
}

#pragma mark - Layout subclass

static char kCacheKey;
static char kOwnerKey;

@interface GVWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation GVWeakBox
@end

// Grid only while the owning list is actually showing the home feed
static BOOL GVLayoutActive(UICollectionViewLayout *layout) {
    GVWeakBox *box = objc_getAssociatedObject(layout, &kOwnerKey);
    if (!GVIsHome(box.object)) return NO;
    return ((UICollectionViewFlowLayout *)layout).scrollDirection == UICollectionViewScrollDirectionVertical;
}

@interface GVLayoutCache : NSObject
@property (nonatomic, copy) NSArray<UICollectionViewLayoutAttributes *> *all;
@property (nonatomic, strong) NSMutableDictionary<NSIndexPath *, UICollectionViewLayoutAttributes *> *cells;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UICollectionViewLayoutAttributes *> *supplementary;
@property (nonatomic) CGSize contentSize;
@property (nonatomic, copy) NSString *signature;
@end
@implementation GVLayoutCache
@end

static GVLayoutCache *GVCache(id self) { return objc_getAssociatedObject(self, &kCacheKey); }

static NSString *GVSuppKey(NSString *kind, NSIndexPath *ip) {
    return [NSString stringWithFormat:@"%@|%ld|%ld", kind, (long)ip.section, (long)ip.item];
}

static Class GVSuperclass(id self) { return class_getSuperclass(object_getClass(self)); }

static CGSize GVSuperContentSize(id self) {
    struct objc_super sup = { self, GVSuperclass(self) };
    return ((CGSize (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(collectionViewContentSize));
}

static NSArray *GVSuperElements(id self, CGRect rect) {
    struct objc_super sup = { self, GVSuperclass(self) };
    return ((NSArray *(*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&sup, @selector(layoutAttributesForElementsInRect:), rect);
}

static NSInteger GVRank(UICollectionViewLayoutAttributes *a) {
    if (a.representedElementCategory == UICollectionElementCategoryCell) return 1;
    return [a.representedElementKind isEqualToString:UICollectionElementKindSectionFooter] ? 2 : 0;
}

static void gv_prepareLayout(UICollectionViewLayout *self, SEL _cmd) {
    struct objc_super sup = { self, GVSuperclass(self) };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);

    if (!GVLayoutActive(self)) { objc_setAssociatedObject(self, &kCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return; }
    CGFloat W = self.collectionView.bounds.size.width;
    CGSize orig = GVSuperContentSize(self);
    // Only re-lay out when the width, item count or total height has changed
    UICollectionView *cv = self.collectionView;
    NSInteger sections = cv.numberOfSections, items = 0;
    for (NSInteger i = 0; i < sections; i++) items += [cv numberOfItemsInSection:i];
    NSString *signature = [NSString stringWithFormat:@"%.1f|%.1f|%.1f|%ld|%ld", W, orig.width, orig.height, (long)sections, (long)items];
    if ([GVCache(self).signature isEqualToString:signature]) return;
    NSArray *attrs = GVSuperElements(self, CGRectMake(0, 0, MAX(W, orig.width), orig.height + 1));
    if (W <= 0 || attrs.count == 0) { objc_setAssociatedObject(self, &kCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return; }

    NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:attrs.count];
    for (UICollectionViewLayoutAttributes *a in attrs) [sorted addObject:[a copy]];
    [sorted sortUsingComparator:^NSComparisonResult(UICollectionViewLayoutAttributes *a, UICollectionViewLayoutAttributes *b) {
        if (a.indexPath.section != b.indexPath.section) return a.indexPath.section < b.indexPath.section ? NSOrderedAscending : NSOrderedDescending;
        NSInteger ra = GVRank(a), rb = GVRank(b);
        if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        if (a.indexPath.item != b.indexPath.item) return a.indexPath.item < b.indexPath.item ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];

    GVLayoutCache *cache = [GVLayoutCache new];
    cache.cells = [NSMutableDictionary dictionary];
    cache.supplementary = [NSMutableDictionary dictionary];

    CGFloat colW = GVColumnWidth(W);
    __block CGFloat y = ((UICollectionViewLayoutAttributes *)sorted.firstObject).frame.origin.y;
    __block NSUInteger col = 0; __block CGFloat rowH = 0;
    NSUInteger gridCells = 0;
    __block NSInteger row = 0;
    void (^flush)(void) = ^{ if (col) { y += rowH + kRowGap - kRowOverlap; col = 0; rowH = 0; row++; } };

    for (UICollectionViewLayoutAttributes *a in sorted) {
        CGRect f = a.frame;
        if (a.representedElementCategory == UICollectionElementCategoryDecorationView) {
            // The original layout's divider decorations no longer match the new arrangement
            a.hidden = YES;
            continue;
        }
        BOOL isCell = a.representedElementCategory == UICollectionElementCategoryCell;
        if (isCell && f.size.width <= colW + 1) {
            // Grid cell
            gridCells++;
            f.origin.x = kMargin + col * (colW + kGap);
            f.origin.y = y;
            a.zIndex = row; // later rows sit on top, so taps on the overlap hit them
            rowH = MAX(rowH, f.size.height);
            if (++col == kColumns) flush();
        } else if (isCell && f.size.height <= 10) {
            // Divider between entries: redundant in the grid
            a.hidden = YES;
            f.origin.y = y; f.size.height = 0;
        } else {
            flush();
            f.origin.y = y;
            y += f.size.height;
        }
        a.frame = f;
        if (isCell) cache.cells[a.indexPath] = a;
        else if (a.representedElementKind) cache.supplementary[GVSuppKey(a.representedElementKind, a.indexPath)] = a;
    }
    flush();
    // Pages without videos (e.g. "More") keep the original layout
    if (gridCells == 0) {
        GVLayoutCache *empty = [GVLayoutCache new];
        empty.signature = signature;
        objc_setAssociatedObject(self, &kCacheKey, empty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGFloat bottomInset = MAX(0, orig.height - CGRectGetMaxY(((UICollectionViewLayoutAttributes *)attrs.lastObject).frame));
    cache.contentSize = CGSizeMake(orig.width, y + bottomInset);
    cache.all = sorted;
    cache.signature = signature;
    objc_setAssociatedObject(self, &kCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGSize gv_contentSize(id self, SEL _cmd) {
    GVLayoutCache *c = GVCache(self);
    return c.all ? c.contentSize : GVSuperContentSize(self);
}

static NSArray *gv_elementsInRect(id self, SEL _cmd, CGRect rect) {
    GVLayoutCache *c = GVCache(self);
    if (!c.all) return GVSuperElements(self, rect);
    NSMutableArray *out = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *a in c.all)
        if (!a.hidden && CGRectIntersectsRect(a.frame, rect)) [out addObject:a];
    return out;
}

static UICollectionViewLayoutAttributes *gv_itemAttrs(id self, SEL _cmd, NSIndexPath *ip) {
    UICollectionViewLayoutAttributes *a = GVCache(self).cells[ip];
    if (a) return a;
    struct objc_super sup = { self, GVSuperclass(self) };
    return ((id (*)(struct objc_super *, SEL, NSIndexPath *))objc_msgSendSuper)(&sup, _cmd, ip);
}

static UICollectionViewLayoutAttributes *gv_suppAttrs(id self, SEL _cmd, NSString *kind, NSIndexPath *ip) {
    UICollectionViewLayoutAttributes *a = GVCache(self).supplementary[GVSuppKey(kind, ip)];
    if (a) return a;
    struct objc_super sup = { self, GVSuperclass(self) };
    return ((id (*)(struct objc_super *, SEL, NSString *, NSIndexPath *))objc_msgSendSuper)(&sup, _cmd, kind, ip);
}

// Appear/disappear animations start from the grid position, not the original position
static UICollectionViewLayoutAttributes *gv_appearingItem(id self, SEL _cmd, NSIndexPath *ip) {
    UICollectionViewLayoutAttributes *a = GVCache(self).cells[ip];
    if (a) { a = [a copy]; a.alpha = 0; return a; }
    struct objc_super sup = { self, GVSuperclass(self) };
    return ((id (*)(struct objc_super *, SEL, NSIndexPath *))objc_msgSendSuper)(&sup, _cmd, ip);
}

static UICollectionViewLayoutAttributes *gv_appearingSupp(id self, SEL _cmd, NSString *kind, NSIndexPath *ip) {
    UICollectionViewLayoutAttributes *a = GVCache(self).supplementary[GVSuppKey(kind, ip)];
    if (a) { a = [a copy]; a.alpha = 0; return a; }
    struct objc_super sup = { self, GVSuperclass(self) };
    return ((id (*)(struct objc_super *, SEL, NSString *, NSIndexPath *))objc_msgSendSuper)(&sup, _cmd, kind, ip);
}

// Create a subclass of the existing layout class (once per class)
static Class GVGridSubclass(Class base) {
    NSString *name = [@"IOSGridView_" stringByAppendingString:NSStringFromClass(base)];
    Class cls = objc_getClass(name.UTF8String);
    if (cls) return cls;
    cls = objc_allocateClassPair(base, name.UTF8String, 0);
    if (!cls) return nil;
    class_addMethod(cls, @selector(prepareLayout), (IMP)gv_prepareLayout, "v@:");
    class_addMethod(cls, @selector(collectionViewContentSize), (IMP)gv_contentSize, "{CGSize=dd}@:");
    class_addMethod(cls, @selector(layoutAttributesForElementsInRect:), (IMP)gv_elementsInRect, "@@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    class_addMethod(cls, @selector(layoutAttributesForItemAtIndexPath:), (IMP)gv_itemAttrs, "@@:@");
    class_addMethod(cls, @selector(layoutAttributesForSupplementaryViewOfKind:atIndexPath:), (IMP)gv_suppAttrs, "@@:@@");
    class_addMethod(cls, @selector(initialLayoutAttributesForAppearingItemAtIndexPath:), (IMP)gv_appearingItem, "@@:@");
    class_addMethod(cls, @selector(finalLayoutAttributesForDisappearingItemAtIndexPath:), (IMP)gv_appearingItem, "@@:@");
    class_addMethod(cls, @selector(initialLayoutAttributesForAppearingSupplementaryElementOfKind:atIndexPath:), (IMP)gv_appearingSupp, "@@:@@");
    class_addMethod(cls, @selector(finalLayoutAttributesForDisappearingSupplementaryElementOfKind:atIndexPath:), (IMP)gv_appearingSupp, "@@:@@");
    objc_registerClassPair(cls);
    return cls;
}

static void GVInstallLayout(YTInnerTubeCollectionViewController *vc) {
    UICollectionViewLayout *layout = [vc collectionViewLayout];
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]]) return;
    if (((UICollectionViewFlowLayout *)layout).scrollDirection != UICollectionViewScrollDirectionVertical) return;
    GVWeakBox *box = [GVWeakBox new]; box.object = vc;
    objc_setAssociatedObject(layout, &kOwnerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([NSStringFromClass(object_getClass(layout)) hasPrefix:@"IOSGridView_"]) return;
    Class sub = GVGridSubclass(object_getClass(layout));
    if (!sub) return;
    object_setClass(layout, sub);
    [layout invalidateLayout];
}

#pragma mark - Tile layout

// Bottom row of a video tile (ELM):  [channel avatar] [title / metadata line] [⋮]
// New:  ⋮ top right inside the thumbnail, wider title, metadata line below it across the full width.
@interface ASDisplayNode : NSObject
@property (nonatomic) CGRect frame;
@property (nonatomic, readonly) NSArray *subnodes;
@property (nonatomic, readonly, weak) ASDisplayNode *supernode;
@property (nonatomic, copy) NSString *accessibilityIdentifier;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly, getter=isNodeLoaded) BOOL nodeLoaded;
- (void)setNeedsDisplay;
@end

static const CGFloat kTilePadding = 12, kMenuInset = 6, kMetaGap = 4;
static const CGFloat kTextScale = 0.85;
static const CGFloat kSmallAvatar = 16, kAvatarGap = 4;
static const CGFloat kChannelLineSpacing = 3, kAvatarNudge = -1.5;
static char kProcessedTextKey;
static char kAvatarSizeKey;

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize;
@end

static CGFloat GVLineWidth(NSAttributedString *s) {
    return ceil([s boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.width);
}

// Shrink the font; for the metadata line, break after the channel name, truncate the
// channel name to one line and indent it for the small channel avatar. Each text only once.
// YouTube uses "truncate tail" as the line break mode, which limits every paragraph to
// one line: switch to word wrapping, the text node enforces the line limit itself.
static void GVRestyleText(ASTextNode *node, BOOL isMeta, CGFloat width, CGFloat indent) {
    if (![node respondsToSelector:@selector(attributedText)]) return;
    NSAttributedString *cur = node.attributedText;
    if (!cur.length || objc_getAssociatedObject(node, &kProcessedTextKey) == cur) return;
    NSMutableAttributedString *m = [cur mutableCopy];
    [m enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, m.length) options:0 usingBlock:^(UIFont *font, NSRange range, BOOL *stop) {
        if (font) [m addAttribute:NSFontAttributeName value:[font fontWithSize:round(font.pointSize * kTextScale * 2) / 2] range:range];
    }];
    NSParagraphStyle *base = [m attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] ?: [NSParagraphStyle defaultParagraphStyle];
    NSMutableParagraphStyle *ps = [base mutableCopy];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    [m addAttribute:NSParagraphStyleAttributeName value:[ps copy] range:NSMakeRange(0, m.length)];
    if (isMeta) {
        NSUInteger firstEnd = m.length;
        // Separator after the channel name: double space (videos) or " · " (playlists, podcasts)
        NSRange gap = [m.string rangeOfString:@"\\s{2,}" options:NSRegularExpressionSearch];
        if (gap.location == NSNotFound) gap = [m.string rangeOfString:@"\\s*·\\s*" options:NSRegularExpressionSearch];
        if (gap.location != NSNotFound && gap.location > 0) {
            [m replaceCharactersInRange:gap withString:@"\n"];
            firstEnd = gap.location;
            // Truncate the channel name to one line
            CGFloat avail = width - indent;
            if (GVLineWidth([m attributedSubstringFromRange:NSMakeRange(0, firstEnd)]) > avail) {
                NSDictionary *attrs = [m attributesAtIndex:0 effectiveRange:NULL];
                NSUInteger lo = 0, hi = firstEnd;
                while (lo < hi) {
                    NSUInteger mid = (lo + hi + 1) / 2;
                    NSMutableAttributedString *probe = [[m attributedSubstringFromRange:NSMakeRange(0, mid)] mutableCopy];
                    [probe appendAttributedString:[[NSAttributedString alloc] initWithString:@"…" attributes:attrs]];
                    if (GVLineWidth(probe) <= avail) lo = mid; else hi = mid - 1;
                }
                NSRange cut = [m.string rangeOfComposedCharacterSequencesForRange:NSMakeRange(lo, firstEnd - lo)];
                [m replaceCharactersInRange:NSMakeRange(lo, cut.location + cut.length - lo) withAttributedString:[[NSAttributedString alloc] initWithString:@"…" attributes:attrs]];
                firstEnd = lo + 1;
            }
        }
        // Channel line: indent for the channel avatar and a little spacing to the line below
        NSMutableParagraphStyle *first = [ps mutableCopy];
        first.firstLineHeadIndent = indent;
        if (firstEnd < m.length) first.paragraphSpacing = kChannelLineSpacing;
        NSRange para = [m.string paragraphRangeForRange:NSMakeRange(0, 0)];
        [m addAttribute:NSParagraphStyleAttributeName value:[first copy] range:para];
        node.maximumNumberOfLines = 2;
    }
    node.attributedText = [m copy];
    objc_setAssociatedObject(node, &kProcessedTextKey, node.attributedText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static char kMenuHitRectKey;

static ASDisplayNode *GVSubnodeWithID(ASDisplayNode *node, NSString *axID) {
    for (ASDisplayNode *sub in node.subnodes)
        if ([sub.accessibilityIdentifier isEqualToString:axID]) return sub;
    return nil;
}

static BOOL GVIsGridTile(ASDisplayNode *row) {
    UIWindow *w = row.nodeLoaded ? row.view.window : nil;
    return w && fabs(row.frame.size.width - GVColumnWidth(w.bounds.size.width)) <= 1;
}

static ASTextNode *GVFirstTextNode(ASDisplayNode *node) {
    if ([node respondsToSelector:@selector(attributedText)]) return (ASTextNode *)node;
    for (ASDisplayNode *sub in node.subnodes) {
        ASTextNode *t = GVFirstTextNode(sub);
        if (t) return t;
    }
    return nil;
}

// Let the text node measure itself: honors the line limit and paragraph style exactly as it draws
static CGFloat GVTextHeight(ASTextNode *node, CGFloat width) {
    if (!node.attributedText.length) return 0;
    return ceil([node calculateSizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
}

// Completely rearranges the bottom row of a grid tile. All values are recomputed
// every time from the width, spacings and text heights, so the result stays the
// same no matter which part of the tile was just re-laid out.
//   [title across the full width]
//   (•) channel name
//   views   age                            ⋮ moves into the thumbnail
static void GVArrangeTile(ASDisplayNode *row) {
    ASDisplayNode *lockup = GVSubnodeWithID(row, @"eml.lockup_metadata");
    ASDisplayNode *menu = GVSubnodeWithID(row, @"eml.overflow_button");
    if (!lockup || !menu || !GVIsGridTile(row)) return;
    // Channel avatar: plain image, with live ring, or multiple channels; in general anything left of the title block
    ASDisplayNode *avatar = GVSubnodeWithID(row, @"eml.avatar");
    if (!avatar) {
        for (ASDisplayNode *sub in row.subnodes) {
            if (sub == lockup || sub == menu) continue;
            // Already shrunk as a channel avatar before, or (the first time) left of the title block
            BOOL known = objc_getAssociatedObject(sub, &kAvatarSizeKey) != nil;
            if (known || (sub.frame.size.width > 0 && CGRectGetMaxX(sub.frame) <= lockup.frame.origin.x + 1)) { avatar = sub; break; }
        }
    }
    CGFloat W = row.frame.size.width, cw = W - 2 * kTilePadding;

    // ⋮ into the top right corner of the thumbnail
    CGFloat ms = menu.frame.size.width;
    menu.frame = CGRectMake(W - ms - kMenuInset, -row.frame.origin.y + kMenuInset, ms, ms);
    if (row.nodeLoaded) {
        row.view.clipsToBounds = NO;
        row.view.layer.masksToBounds = NO;
        objc_setAssociatedObject(row.view, &kMenuHitRectKey, [NSValue valueWithCGRect:CGRectInset(menu.frame, -8, -8)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (menu.nodeLoaded) {
        menu.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        menu.view.layer.cornerRadius = ms / 2;
    }

    // Nesting down to the container holding [title] and [metadata line]
    NSMutableArray<ASDisplayNode *> *chain = [NSMutableArray array];
    ASDisplayNode *stack = lockup;
    while (stack.subnodes.count == 1 && ![stack.subnodes.firstObject respondsToSelector:@selector(attributedText)]) {
        stack = stack.subnodes.firstObject;
        [chain addObject:stack];
    }
    NSArray *parts = stack.subnodes;
    ASDisplayNode *titleBox = parts.count >= 1 ? parts[0] : nil;
    ASDisplayNode *lineBox = parts.count >= 2 ? parts[1] : nil;
    ASTextNode *title = GVFirstTextNode(titleBox ?: stack);
    ASTextNode *line = lineBox ? GVFirstTextNode(lineBox) : nil;

    if (title) GVRestyleText(title, NO, cw, 0);
    if (line) GVRestyleText(line, YES, cw, avatar ? kSmallAvatar + kAvatarGap : 0);
    CGFloat th = title ? GVTextHeight(title, cw) : 0;
    CGFloat lh = line ? GVTextHeight(line, cw) : 0;
    CGFloat total = th + (line ? kMetaGap + lh : 0);

    CGRect lf = lockup.frame;
    lockup.frame = CGRectMake(kTilePadding, lf.origin.y, cw, total);
    for (ASDisplayNode *n in chain) n.frame = CGRectMake(0, 0, cw, total);
    if (titleBox && titleBox != title) titleBox.frame = CGRectMake(0, 0, cw, th);
    if (title) { title.frame = CGRectMake(0, 0, cw, th); [title setNeedsDisplay]; }
    if (lineBox && lineBox != line) lineBox.frame = CGRectMake(0, th + kMetaGap, cw, lh);
    if (line) { line.frame = CGRectMake(0, lineBox == line ? th + kMetaGap : 0, cw, lh); [line setNeedsDisplay]; }

    // Small channel avatar to the left of the channel name
    if (avatar) {
        if (!line) { avatar.frame = CGRectZero; return; }
        UIFont *font = line.attributedText.length ? [line.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil;
        // Lines are taller than the font and the text sits at the bottom of the line:
        // center on the font of the first line
        NSUInteger lines = [line.attributedText.string containsString:@"\n"] ? 2 : 1;
        CGFloat lineBox = (lh - (lines > 1 ? kChannelLineSpacing : 0)) / lines;
        CGFloat glyph = font ? font.lineHeight : lineBox;
        CGPoint center = CGPointMake(kTilePadding + kSmallAvatar / 2, lf.origin.y + th + kMetaGap + lineBox - glyph / 2 + kAvatarNudge);
        CGFloat natural = [objc_getAssociatedObject(avatar, &kAvatarSizeKey) doubleValue];
        if (natural <= 0) {
            natural = avatar.frame.size.width;
            objc_setAssociatedObject(avatar, &kAvatarSizeKey, @(natural), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if ([avatar.accessibilityIdentifier isEqualToString:@"eml.avatar"] || ![avatar.subnodes count]) {
            avatar.frame = CGRectMake(center.x - kSmallAvatar / 2, center.y - kSmallAvatar / 2, kSmallAvatar, kSmallAvatar);
            if (avatar.nodeLoaded) { avatar.view.layer.cornerRadius = kSmallAvatar / 2; avatar.view.clipsToBounds = YES; }
        } else if (avatar.nodeLoaded) {
            // Channel avatar with live ring: scale down as a whole
            CGFloat scale = kSmallAvatar / natural;
            avatar.view.transform = CGAffineTransformIdentity;
            avatar.frame = CGRectMake(0, 0, natural, natural);
            avatar.view.center = center;
            avatar.view.transform = CGAffineTransformMakeScale(scale, scale);
        }
    }
}

// Is the node inside the bottom row of a tile? If so, return that row.
static ASDisplayNode *GVTileRowFor(ASDisplayNode *node) {
    ASDisplayNode *n = node;
    for (int i = 0; i < 7 && n; i++) {
        if (GVSubnodeWithID(n, @"eml.overflow_button") && GVSubnodeWithID(n, @"eml.lockup_metadata")) return n;
        n = n.supernode;
    }
    return nil;
}

%group Main

%hook ELMContainerNode
- (void)layout {
    %orig;
    ASDisplayNode *row = GVTileRowFor((ASDisplayNode *)self);
    if (row) GVArrangeTile(row);
}
%end

%hook _ASDisplayView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    NSValue *extra = objc_getAssociatedObject(self, &kMenuHitRectKey);
    if (extra && CGRectContainsPoint(extra.CGRectValue, point)) return YES;
    return %orig;
}
%end

#pragma mark - Hooks

%hook YTSectionController

- (CGSize)columnSizeForEntry:(id)entry collectionViewSize:(CGSize)size {
    CGSize r = %orig;
    if (GVIsHome([self sectionControllerDelegate]) && GVIsGridEntry(entry))
        r.width = GVColumnWidth(size.width);
    return r;
}

%end

#pragma mark - Preview order

// YouTube plays the preview of the topmost video that still lies far enough inside
// a zone near the top of the screen; at equal height the left one wins. For the
// visibility calculation we report the left column half a row higher:
// the previews then advance evenly in reading order.
static const CGFloat kLeftColumnLead = 0.72; // fraction of the column width, ≈ half a row height
static BOOL gInVisibilityEvent;

%hook ELMIntersectionObserverUtil
+ (void)handleVisibilityEvent:(id)view dx:(int)dx dy:(int)dy isVertical:(BOOL)vertical event:(unsigned long long)event {
    gInVisibilityEvent = vertical;
    %orig;
    gInVisibilityEvent = NO;
}
%end

%hook UIView
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view {
    CGRect r = %orig;
    if (!gInVisibilityEvent) return r;
    // toView:nil converts to window coordinates
    CGFloat colW = GVColumnWidth((view ?: self.window).bounds.size.width);
    if (fabs(r.size.width - colW) <= 2 && fabs(r.origin.x - kMargin) <= 2) {
        // No lead at the very top, so the first row starts on the left
        CGFloat lead = round(colW * kLeftColumnLead);
        UIView *v = self.superview;
        while (v && ![v isKindOfClass:[UICollectionView class]]) v = v.superview;
        UIScrollView *list = (UIScrollView *)v;
        CGFloat scrolled = list ? list.contentOffset.y + list.adjustedContentInset.top : lead;
        r.origin.y -= MIN(lead, MAX(0, scrolled));
    }
    return r;
}
%end

%hook YTInnerTubeCollectionViewController

- (void)viewWillLayoutSubviews {
    %orig;
    if (GVIsHome(self)) GVInstallLayout(self);
    else if ([NSStringFromClass(object_getClass([self collectionViewLayout])) hasPrefix:@"IOSGridView_"] && GVCache([self collectionViewLayout]))
        [[self collectionViewLayout] invalidateLayout];
}

%end

%end // Main

#pragma mark - On/off switch

static NSString *const kEnabledKey = @"IOSGridViewEnabled";
static const NSInteger kSettingsSection = 'igvw';

// Read once per app launch: the hooks are only installed when the tweak is
// enabled, so toggling it only takes effect after a restart.
static BOOL GVEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:kEnabledKey] ? [d boolForKey:kEnabledKey] : YES;
}

static BOOL GVGerman(void) { return [[NSLocale preferredLanguages].firstObject hasPrefix:@"de"]; }

@interface YTSettingsGroupData (IOSGridView)
+ (NSMutableArray <NSNumber *> *)tweaks;
@end
@interface YTSettingsSectionItemManager (IOSGridView)
- (void)updateIOSGridViewSectionWithEntry:(id)entry;
@end

// With YouGroupSettings: add the section to its "Tweaks" group
static void GVAddToTweakGroup(void) {
    Class groupData = objc_getClass("YTSettingsGroupData");
    if (!class_getClassMethod(groupData, @selector(tweaks))) return;
    NSMutableArray *tweaks = [groupData tweaks];
    if (![tweaks containsObject:@(kSettingsSection)]) [tweaks addObject:@(kSettingsSection)];
}

%group Settings

%hook YTSettingsGroupData
// Without YouGroupSettings: insert the section into the first settings group
- (NSArray <NSNumber *> *)orderedCategories {
    GVAddToTweakGroup();
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSMutableArray *cats = [%orig mutableCopy];
    [cats insertObject:@(kSettingsSection) atIndex:0];
    return cats;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    GVAddToTweakGroup();
    NSArray <NSNumber *> *order = %orig;
    NSUInteger i = [order indexOfObject:@(1)];
    if (i == NSNotFound || [order containsObject:@(kSettingsSection)]) return order;
    NSMutableArray *m = [order mutableCopy];
    [m insertObject:@(kSettingsSection) atIndex:i + 1];
    return m;
}
%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateIOSGridViewSectionWithEntry:(id)entry {
    YTSettingsViewController *delegate = [self valueForKey:@"_dataDelegate"];
    BOOL de = GVGerman();
    YTSettingsSectionItem *toggle = [%c(YTSettingsSectionItem) switchItemWithTitle:(de ? @"Aktiviert" : @"Enabled")
        titleDescription:(de ? @"Zeigt die Startseite als Raster mit zwei Videos pro Zeile. Wirkt nach einem Neustart der App."
                             : @"Shows the home feed as a grid with two videos per row. Takes effect after restarting the app.")
        accessibilityIdentifier:nil
        switchOn:GVEnabled()
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kEnabledKey];
            return YES;
        }
        settingItemId:0];
    NSString *title = @"IOSGridView";
    if ([delegate respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [delegate setSectionItems:[@[toggle] mutableCopy] forCategory:kSettingsSection title:title icon:nil titleDescription:nil headerHidden:NO];
    else
        [delegate setSectionItems:[@[toggle] mutableCopy] forCategory:kSettingsSection title:title titleDescription:nil headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == kSettingsSection) { [self updateIOSGridViewSectionWithEntry:entry]; return; }
    %orig;
}
%end

%end // Settings

%ctor {
    %init(Settings);
    if (GVEnabled()) %init(Main);
    // Only after all tweaks have loaded (YouGroupSettings loads later alphabetically)
    dispatch_async(dispatch_get_main_queue(), ^{ GVAddToTweakGroup(); });
}
