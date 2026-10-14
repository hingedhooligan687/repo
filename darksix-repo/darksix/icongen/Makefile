ARCHS = armv7
TARGET = iphone:clang:9.3:6.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = darksix-icongen
darksix-icongen_FILES = main.c icon_core.c
darksix-icongen_FRAMEWORKS = CoreFoundation CoreGraphics ImageIO
darksix-icongen_INSTALL_PATH = /usr/libexec
darksix-icongen_CFLAGS = -Wno-deprecated-module-dot-map -Wno-unused-function -Wno-deprecated-declarations -Wno-error -marm
darksix-icongen_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tool.mk
