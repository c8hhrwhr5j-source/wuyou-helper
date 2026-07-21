# 触控精灵 — TrollStore Lua 脚本自动化容器

## 概述

触控精灵是一款适配 **iOS 15.0~16.6.1**、通过 **TrollStore 巨魔**  直接安装的 IPA 自动化容器程序。内置 Lua 5.4 解释器，支持屏幕截图取色、区域找色、模拟触控点击滑动、脚本编辑运行等核心功能。

**全程用户态 API 开发，不依赖内核漏洞、不越狱、不需要 root 权限。**

## 项目目录结构

```
触控精灵/
├── build.sh                    # WSL2 交叉编译一键构建脚本
├── entitlements.plist          # 巨魔专用权限配置
├── Info.plist                  # 应用基本信息
├── test_script.lua             # 测试用 Lua 脚本
│
├── src/                        # Objective-C 源码
│   ├── main.m                  # 应用入口
│   ├── AppDelegate.h/.m        # 应用代理
│   ├── ViewController.h/.m     # 主界面控制器
│   ├── ScriptEngine.h/.m       # Lua 虚拟机生命周期管理
│   ├── LuaBridge.h/.m          # OC原生函数 → Lua 绑定注册
│   ├── ScreenCapture.h/.m      # 全屏截图 + 像素取色 + 区域找色
│   └── TouchSimulation.h/.m    # 触控模拟（单击/长按/滑动）
│
└── build/                      # 编译产物（自动生成）
    ├── lib/liblua.a            # Lua 5.4.7 静态库
    ├── include/                # Lua C 头文件
    ├── obj/                    # 中间 .o 文件
    ├── app/                    # 可执行文件
    ├── Payload/                # .app Bundle
    └── 触控精灵.ipa             # 最终 IPA
```

## 架构分层

| 层级 | 模块 | 说明 |
|---|---|---|
| **基础层** | entitlements.plist | 关闭沙盒、截图权限、辅助点击、IOHID 事件 |
| **内核运行层** | ScriptEngine + LuaBridge | Lua 5.4 虚拟机创建/销毁、脚本解析执行、异常捕获 |
| **屏幕图像层** | ScreenCapture | IOMobileFramebuffer → IOSurface → BGRA像素 → 取色/找色 |
| **触控模拟层** | TouchSimulation | IOHIDEvent 底层事件发送 → 单击/长按/滑动 |
| **脚本桥接层** | LuaBridge | 9个原生函数注册到 Lua 全局环境 |
| **UI功能层** | ViewController | 脚本编辑器 + 日志面板 + 运行/暂停/停止控制 |
| **打包输出层** | build.sh | arm64交叉编译 → ldid签名 → IPA输出 |

## 必备权限 (entitlements.plist)

| 权限 Key | 用途 |
|---|---|
| `com.apple.private.security.no-sandbox` | **核心** — 关闭沙盒 |
| `com.apple.private.screencapture.capture-all-displays` | 全屏截图 |
| `com.apple.private.iohid.event-system` | 触控事件发送 |
| `com.apple.private.iomobileframebuffer.access` | 帧缓冲读取 |
| `com.apple.private.coresurface.access` | CoreSurface 截图 |
| `dynamic-codesigning` | Lua 动态代码运行 |
| `com.apple.private.skip-library-validation` | 跳过库校验 |
| `platform-application` | 平台应用标识 |

## Lua 接口文档

### 屏幕图像类

```lua
-- 获取屏幕分辨率
w, h = get_screen_size()
-- 返回: 屏幕宽、高 (像素)

-- 获取指定坐标 RGB 颜色值
r, g, b = get_screen_color(x, y)
-- 参数: x, y 屏幕坐标
-- 返回: 红、绿、蓝 分量 (0-255)
-- 越界返回: 0, 0, 0

-- 区域模糊找色
fx, fy = find_color(x1, y1, x2, y2, tr, tg, tb, similarity)
-- 参数:
--   x1,y1    左上角起始坐标
--   x2,y2    右下角结束坐标
--   tr,tg,tb 目标RGB颜色值
--   similarity 相似度 (0-100), 100为完全匹配
-- 返回: 第一个匹配像素坐标
--       未找到返回 0, 0
```

### 触控模拟类

```lua
-- 屏幕坐标单击
click(x, y)

-- 长按（指定按住时长）
long_click(x, y, delay_ms)
-- delay_ms: 按住时长，单位毫秒

-- 滑动
swipe(x1, y1, x2, y2, delay_ms)
-- 从 (x1,y1) 滑动到 (x2,y2)
-- delay_ms: 滑动总时长，单位毫秒
```

### 流程控制类

```lua
-- 延时等待
sleep(ms)
-- ms: 等待时长，单位毫秒
-- 等待期间会检查停止标志，可被 stop_script() 中断

-- 打印运行日志
log("message")

-- 强制停止当前脚本
stop_script()
```

## Lua 静态库集成步骤

1. **下载 Lua 5.4.7 源码**
   ```bash
   curl -LO https://www.lua.org/ftp/lua-5.4.7.tar.gz
   tar xzf lua-5.4.7.tar.gz
   ```

2. **编译 arm64 iOS 静态库**（由 build.sh 自动完成）
   ```bash
   clang -arch arm64 -isysroot $IOS_SDK \
         -miphoneos-version-min=15.0 \
         -DLUA_USE_IOS -c lua-5.4.7/src/*.c
   ar rcs liblua.a *.o
   ```

3. **引入头文件**
   ```objc
   #include "lua.h"
   #include "lualib.h"
   #include "lauxlib.h"
   ```

4. **链接**
   ```
   -L./build/lib -llua
   ```

## 原生函数注册 Lua 绑定代码

详见 `src/LuaBridge.m`，核心机制：

```objc
// 1. 定义 C 函数
static int l_click(lua_State *L) {
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    [[TouchSimulation shared] clickAtX:x y:y];
    return 0;  // 返回值数量
}

// 2. 注册到 Lua 全局表
static const luaL_Reg g_nativeFunctions[] = {
    {"click", l_click},
    // ...
    {NULL, NULL}
};

void lua_register_all_native_functions(lua_State *L) {
    lua_getglobal(L, "_G");
    for (const luaL_Reg *lib = g_nativeFunctions; lib->func; lib++) {
        lua_pushcfunction(L, lib->func);
        lua_setfield(L, -2, lib->name);
    }
    lua_pop(L, 1);
}
```

## 测试脚本

```lua
-- 循环找色点击示例
while true do
    local tx, ty = find_color(200, 300, 600, 900, 255, 255, 255, 90)
    if tx > 0 and ty > 0 then
        log("找到目标: " .. tx .. "," .. ty)
        click(tx, ty)
        sleep(800)
    end
    sleep(300)
end
```

## WSL2 一键编译打包

```bash
# 前置准备
# 1. 从 macOS Xcode 复制 SDK 到 WSL2
#    cp -r /Applications/Xcode.app/.../iPhoneOS.sdk ~/ios-sdk/

# 2. 一键构建
chmod +x build.sh
./build.sh build

# 输出: build/触控精灵.ipa
# 通过 TrollStore 直接安装
```

## 禁止内容

- ❌ 不编写内核漏洞利用代码
- ❌ 不编写 setuid 提权 root 代码
- ❌ 不编写手机重启、关机、系统修改代码
- ❌ 不做 APP 注入、全局 Hook、越狱功能
- ❌ 不接入第三方付费脚本框架

## 技术依赖

| 依赖 | 用途 | 来源 |
|---|---|---|
| Lua 5.4.7 | 脚本解释器 | lua.org |
| IOMobileFramebuffer | 屏幕截图 | iOS Private |
| IOSurface | 像素数据读取 | iOS Public |
| IOHIDEvent | 触控事件发送 | IOKit Private |
| ldid | 权限签名 | Procursus |
