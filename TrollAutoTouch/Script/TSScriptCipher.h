//
//  TSScriptCipher.h
//  TrollAutoTouch
//
//  Lua 脚本加密 (.tas) —— 对齐原版 TrollAutoScript 的"加密脚本"功能。
//
//  加密后脚本文件名不变、后缀由 .lua 变为 .tas：
//    - 脚本列表仍可显示、可运行
//    - 源码无法以明文查看
//
//  支持两种文件格式（共用同一 XXTEA 载荷封装）:
//    单脚本: "TAS1" 魔数头 + base64( [明文长度:4B][XXTEA 密文] )
//    整包:   "TAP1" 魔数头 + base64( [包数据长度:4B][XXTEA 密文] ) —— 项目整包加密
//  XXTEA 为纯 C 实现，不依赖任何外部加密框架。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScriptCipher : NSObject

/// 判断一段文本是否为单个 .lua 脚本的加密格式（检测 "TAS1" 魔数头）
+ (BOOL)isEncryptedContent:(NSString *)content;

/// 判断一段文本是否为"整包加密"的项目包（检测 "TAP1" 魔数头）
+ (BOOL)isProjectPackageContent:(NSString *)content;

/// 加密 Lua 源码 -> .tas 文件内容（UTF-8 编码后 XXTEA 加密 + base64）
+ (nullable NSString *)encryptScript:(NSString *)plainText;

/// 解密 .tas 文件内容 -> Lua 源码；格式非法 / 密钥不匹配返回 nil
+ (nullable NSString *)decryptScript:(NSString *)cipherText;

/// 整包加密: 项目目录打包得到的 zip 数据 → .tas 项目包内容
+ (nullable NSString *)encryptProjectData:(NSData *)projectZipData;

/// 整包解密: .tas 项目包内容 → 项目 zip 数据；格式非法 / 密钥不匹配返回 nil
+ (nullable NSData *)decryptProjectData:(NSString *)cipherText;

@end

NS_ASSUME_NONNULL_END
