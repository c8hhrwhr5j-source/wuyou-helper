//
//  TSAppNodeInfo.m
//  TrollAutoTouch
//

#import "TSAppNodeInfo.h"
#import "TSHIDEventTouch.h"

#pragma mark - TSAppNode

@implementation TSAppNode

- (CGPoint)centerPoint {
    return CGPointMake(CGRectGetMidX(self.frame), CGRectGetMidY(self.frame));
}

- (CGPoint)randomTapPoint {
    // 返回节点中心 ± 小偏移，避免反作弊检测
    CGFloat dx = (CGFloat)(arc4random_uniform((uint32_t)(self.frame.size.width * 0.4f)))
                 - self.frame.size.width * 0.2f;
    CGFloat dy = (CGFloat)(arc4random_uniform((uint32_t)(self.frame.size.height * 0.4f)))
                 - self.frame.size.height * 0.2f;
    return CGPointMake(CGRectGetMidX(self.frame) + dx, CGRectGetMidY(self.frame) + dy);
}

@end

#pragma mark - TSAppNodeInfo

@interface TSAppNodeInfo ()
@property (nonatomic, strong, nullable) TSAppNode *cachedTree;
@end

@implementation TSAppNodeInfo

+ (instancetype)shared {
    static TSAppNodeInfo *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[TSAppNodeInfo alloc] init]; });
    return instance;
}

#pragma mark - 树构建

- (nullable TSAppNode *)fullTree {
    __block TSAppNode *root = nil;
    if ([NSThread isMainThread]) {
        root = [self _buildTreeFromView:[self _keyWindow]];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            root = [self _buildTreeFromView:[self _keyWindow]];
        });
    }
    return root;
}

- (UIView *)_keyWindow {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return scene.keyWindow;
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

- (TSAppNode *)_buildTreeFromView:(UIView *)view {
    if (!view) return nil;
    
    TSAppNode *node = [[TSAppNode alloc] init];
    node.address = (uintptr_t)(__bridge void *)view;
    node.className = NSStringFromClass([view class]);
    node.superClassName = NSStringFromClass([[view class] superclass]);
    node.text = view.accessibilityLabel ?: @"";
    node.accessibilityLabel = view.accessibilityLabel ?: @"";
    node.frame = view.frame;
    node.isHidden = view.isHidden;
    node.alpha = view.alpha;
    
    NSArray *subviews = view.subviews;
    NSMutableArray<TSAppNode *> *children = [NSMutableArray arrayWithCapacity:subviews.count];
    for (UIView *sub in subviews) {
        TSAppNode *child = [self _buildTreeFromView:sub];
        if (child) [children addObject:child];
    }
    node.subviews = children;
    
    return node;
}

#pragma mark - JSON 输出

- (NSString *)fullTreeJSON {
    TSAppNode *root = [self fullTree];
    if (!root) return @"{}";
    
    NSDictionary *json = [self _jsonFromNode:root];
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

- (NSDictionary *)_jsonFromNode:(TSAppNode *)node {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = node.className;
    d[@"superClass"] = node.superClassName;
    d[@"text"] = node.text;
    d[@"lable"] = node.accessibilityLabel;
    d[@"x"] = @(node.frame.origin.x);
    d[@"y"] = @(node.frame.origin.y);
    d[@"width"] = @(node.frame.size.width);
    d[@"height"] = @(node.frame.size.height);
    d[@"isHidden"] = @(node.isHidden);
    d[@"alpha"] = @(node.alpha);
    d[@"address"] = @(node.address);
    
    NSMutableArray *children = [NSMutableArray array];
    for (TSAppNode *child in node.subviews) {
        [children addObject:[self _jsonFromNode:child]];
    }
    d[@"subviews"] = children;
    return d;
}

#pragma mark - 查找方法

- (NSArray<TSAppNode *> *)findByClassName:(NSString *)className {
    return [self findByClassName:className superClass:nil];
}

- (NSArray<TSAppNode *> *)findByClassName:(NSString *)className superClass:(nullable NSString *)superClass {
    TSAppNode *tree = self.cachedTree ?: [self fullTree];
    NSMutableArray *result = [NSMutableArray array];
    [self _findNodeByClass:className superClass:superClass inTree:tree result:result];
    return result;
}

- (void)_findNodeByClass:(NSString *)cn superClass:(NSString *)sc inTree:(TSAppNode *)node result:(NSMutableArray *)result {
    if (!node) return;
    if ([node.className isEqualToString:cn] || [node.className hasSuffix:cn]) {
        if (!sc || [node.superClassName containsString:sc] || [node.superClassName isEqualToString:sc]) {
            [result addObject:node];
        }
    }
    for (TSAppNode *child in node.subviews) {
        [self _findNodeByClass:cn superClass:sc inTree:child result:result];
    }
}

- (NSArray<TSAppNode *> *)findByText:(NSString *)text {
    return [self findByText:text className:nil];
}

- (NSArray<TSAppNode *> *)findByText:(NSString *)text className:(nullable NSString *)className {
    TSAppNode *tree = self.cachedTree ?: [self fullTree];
    NSMutableArray *result = [NSMutableArray array];
    [self _findNodeByText:text className:className inTree:tree result:result];
    return result;
}

- (void)_findNodeByText:(NSString *)text className:(NSString *)cn inTree:(TSAppNode *)node result:(NSMutableArray *)result {
    if (!node) return;
    if ([node.text containsString:text] || [node.accessibilityLabel containsString:text]) {
        if (!cn || [node.className isEqualToString:cn] || [node.className hasSuffix:cn]) {
            [result addObject:node];
        }
    }
    for (TSAppNode *child in node.subviews) {
        [self _findNodeByText:text className:cn inTree:child result:result];
    }
}

- (NSArray<TSAppNode *> *)findByLabel:(NSString *)label {
    return [self findByLabel:label className:nil];
}

- (NSArray<TSAppNode *> *)findByLabel:(NSString *)label className:(nullable NSString *)className {
    // 与 findByText 类似, 但更严格匹配 accessibilityLabel
    TSAppNode *tree = self.cachedTree ?: [self fullTree];
    NSMutableArray *result = [NSMutableArray array];
    [self _findNodeByLabel:label className:className inTree:tree result:result];
    return result;
}

- (void)_findNodeByLabel:(NSString *)label className:(NSString *)cn inTree:(TSAppNode *)node result:(NSMutableArray *)result {
    if (!node) return;
    if ([node.accessibilityLabel isEqualToString:label]) {
        if (!cn || [node.className isEqualToString:cn] || [node.className hasSuffix:cn]) {
            [result addObject:node];
        }
    }
    for (TSAppNode *child in node.subviews) {
        [self _findNodeByLabel:label className:cn inTree:child result:result];
    }
}

- (nullable TSAppNode *)findByPath:(NSString *)path {
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count == 0) return nil;
    
    TSAppNode *tree = self.cachedTree ?: [self fullTree];
    TSAppNode *current = tree;
    
    for (NSString *part in parts) {
        if (!current) return nil;
        BOOL found = NO;
        for (TSAppNode *child in current.subviews) {
            if ([child.className isEqualToString:part] || [child.className hasSuffix:part]) {
                current = child;
                found = YES;
                break;
            }
        }
        if (!found) return nil;
    }
    return current;
}

- (nullable TSAppNode *)findSuperView:(TSAppNode *)node withClass:(NSString *)className {
    if (!node || !className) return nil;
    
    // 通过 address 获取真实 UIView，沿 superview 链向上查找
    UIView *view = (__bridge UIView *)(void *)node.address;
    UIView *superV = view.superview;
    
    while (superV) {
        NSString *superClass = NSStringFromClass([superV class]);
        if ([superClass isEqualToString:className] || [superClass hasSuffix:className]) {
            // 从缓存的树中查找对应地址
            TSAppNode *tree = self.cachedTree ?: [self fullTree];
            return [self _findNodeByAddress:(uintptr_t)(__bridge void *)superV inTree:tree];
        }
        superV = superV.superview;
    }
    return nil;
}

- (TSAppNode *)_findNodeByAddress:(uintptr_t)addr inTree:(TSAppNode *)node {
    if (!node) return nil;
    if (node.address == addr) return node;
    for (TSAppNode *child in node.subviews) {
        TSAppNode *found = [self _findNodeByAddress:addr inTree:child];
        if (found) return found;
    }
    return nil;
}

- (nullable TSAppNode *)findSubView:(TSAppNode *)node withClass:(NSString *)className {
    if (!node) return nil;
    for (TSAppNode *child in node.subviews) {
        if ([child.className isEqualToString:className] || [child.className hasSuffix:className]) {
            return child;
        }
        TSAppNode *r = [self findSubView:child withClass:className];
        if (r) return r;
    }
    return nil;
}

#pragma mark - 操作

- (BOOL)setText:(NSString *)text forNode:(TSAppNode *)node {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIView *view = (__bridge UIView *)(void *)node.address;
        if ([view isKindOfClass:[UITextField class]]) {
            [(UITextField *)view setText:text];
            ok = YES;
        } else if ([view isKindOfClass:[UITextView class]]) {
            [(UITextView *)view setText:text];
            ok = YES;
        } else if ([view isKindOfClass:[UILabel class]]) {
            [(UILabel *)view setText:text];
            ok = YES;
        }
    });
    return ok;
}

- (BOOL)tapNode:(TSAppNode *)node {
    [[TSHIDEventTouch shared] tapAtPoint:node.centerPoint duration:0.05];
    return YES;
}

- (BOOL)longTapNode:(TSAppNode *)node duration:(NSTimeInterval)duration {
    [[TSHIDEventTouch shared] tapAtPoint:node.centerPoint duration:duration];
    return YES;
}

#pragma mark - 缓存

- (void)keepTree {
    self.cachedTree = [self fullTree];
}

- (void)unkeepTree {
    self.cachedTree = nil;
}

- (void)keep {
    [self keepTree];
}

- (void)unKeep {
    [self unkeepTree];
}

- (NSString *)info {
    return [self fullTreeJSON];
}

@end
