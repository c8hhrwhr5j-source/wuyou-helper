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

/// 解压 zip: 命中 match 的条目**只解到内存返回、不落盘**, 其余条目正常解压到 destDir。
/// match 为空表示全部落盘(等价于 unzipData:toDirectory:error:)。
/// 成功返回命中条目表(相对路径→数据, 可能为空字典); 失败返回 nil 并通过 error 输出原因。
+ (nullable NSDictionary<NSString *, NSData *> *)unzipData:(NSData *)data
                                               toDirectory:(NSString *)destDir
                                            entriesMatching:(nullable BOOL (^)(NSString *name))match
                                                      error:(NSString *_Nullable *_Nullable)error;

/// 把目录(含子目录)打包成标准 zip 数据(method 0 stored, UTF-8 文件名)。
/// 与扩展端 packer 产出的 .tep 规范一致, 可用本类 unzipData: 还原。
/// 隐藏文件(. 开头)/常见垃圾文件不入包; 失败返回 nil 并通过 error 输出原因(可为 nil)。
+ (nullable NSData *)zipDataFromDirectory:(NSString *)dir error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
