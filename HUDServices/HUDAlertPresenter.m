//
//  HUDAlertPresenter.m
//  HUDServices
//
//  通过 dispatch_semaphore 实现后台线程阻塞等待 UIAlertController 交互结果。
//

#import "HUDAlertPresenter.h"

@implementation HUDAlertPresenter {
    __weak UIViewController *_presenter;
}

- (instancetype)initWithPresenter:(UIViewController *)presenter {
    self = [super init];
    if (self) {
        _presenter = presenter;
    }
    return self;
}

- (NSString *)presentAlertWithTitle:(NSString *)title
                            message:(NSString *)message
                            buttons:(NSArray<NSString *> *)buttons
                            timeout:(NSTimeInterval)timeout {
    if (!_presenter) {
        return nil;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *result = nil;
    __block BOOL finished = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];

        // 按钮语义: 显式按钮优先; 无按钮且 timeout>0 为纯自动消失;
        // 无按钮且永久显示时兜底一个"确定"避免无法关闭。
        NSArray *buttonTitles;
        if (buttons && buttons.count > 0) {
            buttonTitles = buttons;
        } else if (timeout > 0) {
            buttonTitles = @[];
        } else {
            buttonTitles = @[@"确定"];
        }
        for (NSString *buttonTitle in buttonTitles) {
            [alert addAction:[UIAlertAction actionWithTitle:buttonTitle
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                result = action.title;
                finished = YES;
                dispatch_semaphore_signal(sem);
            }]];
        }

        [self->_presenter presentViewController:alert animated:YES completion:nil];

        if (timeout > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!finished) {
                    finished = YES;
                    [alert dismissViewControllerAnimated:YES completion:^{
                        dispatch_semaphore_signal(sem);
                    }];
                }
            });
        }
    });

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return result;
}

@end
