ARCHS = arm64 arm64e
TARGET = iphone:clang:16.6:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WuyouTweak

WuyouTweak_FILES = Tweak.xm \
                    TouchSimulation.m \
                    ScriptEngine.m \
                    LuaBridge.m \
                    ScreenCapture.m \
                    DeviceInfo.m

WuyouTweak_FRAMEWORKS = UIKit CoreGraphics CoreFoundation IOKit
WuyouTweak_PRIVATE_FRAMEWORKS = IOKit

WuyouTweak_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function -Wno-deprecated-declarations
WuyouTweak_LDFLAGS = -lz

include $(THEOS_MAKE_PATH)/tweak.mk