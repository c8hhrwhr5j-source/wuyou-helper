//
//  TSHUDPrivate.h
//  TrollAutoTouch
//
//  进程内 HUD 宿主所需的私有框架 API 声明。
//
//  说明:
//  - 这些类来自 SpringBoardServices 私有框架, 本工程 CLANG_ENABLE_MODULES=NO
//    且不引入私有框架头文件, 故手动声明。
//  - 编译期仅通过 NSClassFromString + NSSelectorFromString 动态获取类与选择器,
//    不产生私有类符号引用; 主 target 的 OTHER_LDFLAGS 同时带有
//    -Wl,-undefined,dynamic_lookup 兜底, 与 TSInjectedTouchService 策略一致。
//  - 用法与系统行为参考 TrollAutoScript (原版 TrollAutoTouch 参考实现) 的 HUD 服务。
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// SBSAccessibilityWindowHostingController (SpringBoardServices)
// 把本进程指定 CAContext 托管到 SpringBoard 的 accessibility 窗口层,
// 使其内容显示在任意前台 app 之上 (逆向自 AutoGoRunner/agoverlayd)。
// 编译期不直接引用该符号 (NSClassFromString 运行时获取)。
// ─────────────────────────────────────────────────────────────────────────────
@interface SBSAccessibilityWindowHostingController : NSObject

// 注册: 把 contextId 对应的 CAContext 以指定层级显示 (level 10000 高于普通 app)
- (void)registerWindowWithContextID:(unsigned)contextId atLevel:(double)level;
// 注销: 解除托管
- (void)unregisterWindowWithContextID:(unsigned)contextId;

@end

// CALayer 私有属性 contextId: 当前 layer 关联的 CAContext 标识。
// 供 SBSAccessibilityWindowHostingController 托管使用; 用 respondsToSelector 兜底。
@interface CALayer (TSHUDPrivate)
@property (nonatomic, readonly) unsigned contextId;
@end

// ─────────────────────────────────────────────────────────────────────────────
// CAContext (QuartzCore 私有类) —— 显式创建远程渲染上下文。
// 逆向自 Go 版 AutoGoRunner.__fbInstallCAContextOverlay / floatball:
//   1. cls = NSClassFromString(@"CAContext")
//   2. ctx = [cls remoteContextWithOptions:@{@"kCAContextIgnoresHitTest": @YES}]
//   3. [ctx setLayer:windowLayer]      // 把本地 layer 挂进远程上下文
//   4. ctxId = [ctx contextId]         // 显式创建 → contextId 一定非零
//   5. [CATransaction flush]           // 提交渲染
// 之后 SBSAccessibilityWindowHostingController 用 ctxId 托管到系统级。
// 编译期不直接引用 (NSClassFromString + methodForSelector 运行时调用)。
// ─────────────────────────────────────────────────────────────────────────────
// CAContext 的私有头不在 SDK 中, 类/选择器均运行时解析,
// 无需在此声明 @interface; 具体调用见 TSHUDHost.m _createCAContextId。

NS_ASSUME_NONNULL_END
