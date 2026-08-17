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

// ── 控制命令 (app -> dylib) ─────────────────────────────────────────
// count 字段使用保留值 TS_CTRL_FLAG 标识控制包(而非触摸包):
//   [0]=TS_TOUCH_MAGIC  [1]=TS_CTRL_FLAG  [2]=cmd
#define TS_CTRL_FLAG          0xF0
#define TS_CTRL_VOLUME_ON     0x01   // 启用音量键控制面板(脚本运行时由 app 打开)
#define TS_CTRL_VOLUME_OFF    0x02   // 禁用音量键控制面板(脚本结束/停止时关闭)
#define TS_CTRL_VOLUME_KEY    0x03   // 音量键已被按下 -> 弹出控制面板 (音量键识别在 app 进程内完成)

// ── 控制事件 (dylib -> app) ─────────────────────────────────────────
// 独立 magic 0x55 区分方向:
//   [0]=TS_EVENT_MAGIC  [1]=0x01  [2]=event
#define TS_EVENT_MAGIC        0x55
#define TS_EVENT_PAUSE        0x01   // 用户在面板选择"暂停"
#define TS_EVENT_RESUME       0x02   // 用户在面板选择"继续"
#define TS_EVENT_STOP         0x03   // 用户在面板选择"停止"

#endif /* TSInjectedTouchService_h */
