//
//  TSToolExecutor.h
//  TrollAutoTouch
//
//  系统工具执行器 —— 对应原版 bin/ 目录下的 busybox 工具集。
//
//  在 ObjC 层实现常用系统工具功能，不依赖外部二进制文件。
//
//  功能:
//   - Shell 命令执行(posix_spawn)
//   - 文件管理(复制/移动/删除/列出/权限)
//   - 进程管理(查询/终止)
//   - 网络工具(IP/端口检查/HTTP 请求)
//   - Lua 脚本接口(供 tas.* API 调用)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 命令执行结果
@interface TSCmdResult : NSObject
@property (nonatomic, assign) int           exitCode;
@property (nonatomic, copy)   NSString     *standardOutput;
@property (nonatomic, copy)   NSString     *standardError;
@property (nonatomic, assign) NSTimeInterval elapsed;
@end

/// 进程信息
@interface TSProcessInfo : NSObject
@property (nonatomic, assign) pid_t      pid;
@property (nonatomic, copy)   NSString  *name;
@property (nonatomic, copy)   NSString  *path;
@property (nonatomic, strong) NSDate    *startTime;
@end

/// 文件条目
@interface TSFileEntry : NSObject
@property (nonatomic, copy)   NSString  *name;
@property (nonatomic, copy)   NSString  *path;
@property (nonatomic, assign) BOOL       isDirectory;
@property (nonatomic, assign) off_t      size;
@property (nonatomic, strong) NSDate    *modificationDate;
@property (nonatomic, assign) mode_t     permissions;
@property (nonatomic, copy)   NSString  *owner;
@end

@interface TSToolExecutor : NSObject

+ (instancetype)shared;

#pragma mark - Shell 命令

/// 执行 Shell 命令并返回结果
- (TSCmdResult *)executeCommand:(NSString *)command;

/// 执行 Shell 命令(指定超时)
- (TSCmdResult *)executeCommand:(NSString *)command timeout:(NSTimeInterval)timeout;

/// 异步执行 Shell 命令
- (void)executeCommand:(NSString *)command completion:(void(^)(TSCmdResult *result))completion;

#pragma mark - 文件管理

/// 列出目录内容
- (NSArray<TSFileEntry *> *)listDirectory:(NSString *)path;

/// 列出目录(递归)
- (NSArray<TSFileEntry *> *)listDirectoryRecursive:(NSString *)path;

/// 文件是否存在
- (BOOL)fileExists:(NSString *)path;

/// 文件大小
- (off_t)fileSize:(NSString *)path;

/// 读文本文件
- (nullable NSString *)readTextFile:(NSString *)path;

/// 写文本文件
- (BOOL)writeTextFile:(NSString *)path content:(NSString *)content;

/// 复制文件/目录
- (BOOL)copyItem:(NSString *)src to:(NSString *)dst;

/// 移动文件/目录
- (BOOL)moveItem:(NSString *)src to:(NSString *)dst;

/// 删除文件/目录
- (BOOL)removeItem:(NSString *)path;

/// 创建目录
- (BOOL)createDirectory:(NSString *)path;

/// 检查路径权限
- (BOOL)isReadable:(NSString *)path;
- (BOOL)isWritable:(NSString *)path;
- (BOOL)isExecutable:(NSString *)path;

/// 获取文件信息
- (nullable TSFileEntry *)fileInfo:(NSString *)path;

#pragma mark - 进程管理

/// 获取当前运行进程列表
- (NSArray<TSProcessInfo *> *)runningProcesses;

/// 根据名称查找进程
- (NSArray<TSProcessInfo *> *)findProcessesByName:(NSString *)name;

/// 根据 PID 查找进程
- (nullable TSProcessInfo *)processInfoForPID:(pid_t)pid;

/// 终止进程(需要相应权限)
- (BOOL)killProcess:(pid_t)pid;
- (BOOL)killProcessByName:(NSString *)name;

/// 进程是否存在
- (BOOL)processExists:(pid_t)pid;

#pragma mark - 网络工具

/// 获取所有网络接口信息
- (NSDictionary<NSString *, NSDictionary *> *)networkInterfaces;

/// 检查端口是否可用
- (BOOL)isPortAvailable:(uint16_t)port;

/// 获取 WiFi IP 地址
- (nullable NSString *)wifiIPAddress;

/// 获取蜂窝 IP 地址
- (nullable NSString *)cellularIPAddress;

/// HTTP GET 请求(用于 Lua tas.httpGet)
- (void)httpGet:(NSString *)url completion:(void(^)(NSData * _Nullable data, NSError * _Nullable error))completion;

/// HTTP POST 请求(用于 Lua tas.httpPost)
- (void)httpPost:(NSString *)url body:(NSData *)body contentType:(NSString *)contentType
      completion:(void(^)(NSData * _Nullable data, NSError * _Nullable error))completion;

#pragma mark - 设备工具

/// 获取磁盘空间信息
- (NSDictionary *)diskInfo;

/// 获取内存使用信息
- (NSDictionary *)memoryInfo;

/// 获取 CPU 使用信息
- (NSDictionary *)cpuInfo;

/// 系统运行时间
- (NSTimeInterval)systemUptime;

@end

NS_ASSUME_NONNULL_END
