//
//  TSInjectedTouchService.h
//  TrollAutoTouch
//
//  注入式触摸服务协议定义（app 端客户端 <-> SpringBoard 内服务端共用）。
//
//  通信方式: TCP socket, 监听 127.0.0.1:23333
//  指令格式:
//    [0]  magic  = 0x54
//    [1]  count  (1~10)  本包包含的手指数
//    每根手指 9 字节:
//      [0] type    0=down  1=move  2=up
//      [1] index   手指索引 (0~9)
//      [2..5] float32 x  (0~1 归一化坐标, 物理像素/屏宽)
//      [6..9] float32 y  (0~1 归一化坐标)
//

#ifndef TSInjectedTouchService_h
#define TSInjectedTouchService_h

#define TS_TOUCH_PORT          23333
#define TS_TOUCH_MAGIC         0x54
#define TS_TOUCH_MAX_FINGERS   10
#define TS_TOUCH_PER_FINGER    9   // type(1) + index(1) + x(4) + y(4)

// 触摸指令类型
#define TS_TOUCH_TYPE_DOWN     0
#define TS_TOUCH_TYPE_MOVE     1
#define TS_TOUCH_TYPE_UP       2

#endif /* TSInjectedTouchService_h */
