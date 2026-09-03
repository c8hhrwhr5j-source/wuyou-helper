//
//  TSZip.h
//  AutoTouc
//
//  极简 ZIP 解压器: 解析 AutoTouc 扩展打包的 .tep(标准 ZIP) 并释放到目标目录。
//  只支持 method 0(stored) / 8(deflate), 依赖系统 libz(-lz), 无第三方库。
//  安全: 拒绝路径穿越(../)、绝对路径、data descriptor、超大文件。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSZip : NSObject

/// 将 zip 数据解压到 destDir(需已存在)。
/// 成功返回 YES; 失败返回 NO 并通过 error 输出原因(可为 nil)。
+ (BOOL)unzipData:(NSData *)data toDirectory:(NSString *)destDir error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
