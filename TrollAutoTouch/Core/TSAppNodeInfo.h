//
//  TSAppNodeInfo.h
//  TrollAutoTouch
//
//  UI 层次遍历与节点查找 —— 对应原版 appNode 原生模块。
//  通过 UIApplication window 层级遍历当前应用的视图树，
//  支持按 className / text / label / path 查找节点。
//
//  iOS 限制: TrollStore App 以普通 App 身份运行(非 XCTest Runner)，
//  因此只能遍历本进程的视图树。跨进程 UI 遍历需要 XCTest/XCTAutomationSupport,
//  仅在 XCUITest 环境中可用。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UI 节点信息
@interface TSAppNode : NSObject

@property (nonatomic, assign) uintptr_t address;        // 内存地址(唯一标识)
@property (nonatomic, copy)   NSString *className;
@property (nonatomic, copy)   NSString *superClassName;
@property (nonatomic, copy)   NSString *text;            // accessibilityLabel
@property (nonatomic, copy)   NSString *accessibilityLabel;
@property (nonatomic, assign) CGRect frame;              // 逻辑坐标
@property (nonatomic, assign) BOOL isHidden;
@property (nonatomic, assign) CGFloat alpha;
@property (nonatomic, strong) NSArray<TSAppNode *> *subviews;

/// 获取中心点
- (CGPoint)centerPoint;

/// 获取点击区域(随机点)
- (CGPoint)randomTapPoint;

@end

@interface TSAppNodeInfo : NSObject

+ (instancetype)shared;

/// 获取当前 KeyWindow 的完整视图树(JSON 字符串)
- (NSString *)fullTreeJSON;

/// 获取当前 KeyWindow 的完整视图树
- (nullable TSAppNode *)fullTree;

/// 按 className 查找节点(可指定 superClass)
- (NSArray<TSAppNode *> *)findByClassName:(NSString *)className;
- (NSArray<TSAppNode *> *)findByClassName:(NSString *)className superClass:(nullable NSString *)superClass;

/// 按文本查找
- (NSArray<TSAppNode *> *)findByText:(NSString *)text;
- (NSArray<TSAppNode *> *)findByText:(NSString *)text className:(nullable NSString *)className;

/// 按 accessibilityLabel 查找
- (NSArray<TSAppNode *> *)findByLabel:(NSString *)label;
- (NSArray<TSAppNode *> *)findByLabel:(NSString *)label className:(nullable NSString *)className;

/// 按视图路径查找(如 "UIWindow/UITransitionView/UIButton")
- (nullable TSAppNode *)findByPath:(NSString *)path;

/// 对某个节点查找其父视图(向上查)
- (nullable TSAppNode *)findSuperView:(TSAppNode *)node withClass:(NSString *)className;

/// 对某个节点查找其子视图(向下查)
- (nullable TSAppNode *)findSubView:(TSAppNode *)node withClass:(NSString *)className;

/// 对节点设置文本(仅 UITextField/UITextView/UILabel)
- (BOOL)setText:(NSString *)text forNode:(TSAppNode *)node;

/// 对节点执行点击
- (BOOL)tapNode:(TSAppNode *)node;

/// 对节点执行长时间点击
- (BOOL)longTapNode:(TSAppNode *)node duration:(NSTimeInterval)duration;

/// keep/unkeep 缓存视图树(避免每次重新遍历)
- (void)keepTree;
- (void)unkeepTree;

/// 脚本用简洁方法: appNode.info(), appNode.keep(), appNode.unKeep()
- (NSString *)info;      // 返回 JSON 树
- (void)keep;            // 缓存
- (void)unKeep;          // 清除缓存

@end

NS_ASSUME_NONNULL_END
