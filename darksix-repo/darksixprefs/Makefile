ARCHS = armv7
TARGET = iphone:clang:9.3:6.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DarkSixPrefs
DarkSixPrefs_FILES = DSRootListController.m
DarkSixPrefs_INSTALL_PATH = /Library/PreferenceBundles
DarkSixPrefs_FRAMEWORKS = UIKit
DarkSixPrefs_CFLAGS = -Wno-deprecated-module-dot-map -Wno-unused-function -Wno-deprecated-declarations -Wno-error -marm
DarkSixPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
