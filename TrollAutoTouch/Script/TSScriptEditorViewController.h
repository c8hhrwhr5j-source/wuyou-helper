//
//  TSScriptEditorViewController.h
//  TrollAutoTouch
//
//  全屏 Lua 文本编辑器
//  右上角"保存"，左上角"取消"；保存后写回文件并退出，取消则放弃所有修改。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSScriptEditorViewController : UIViewController

/// 要编辑的文件完整路径 (.lua)
@property (nonatomic, copy) NSString *filePath;

@end

NS_ASSUME_NONNULL_END
