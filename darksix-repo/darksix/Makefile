# iPhone 5 runs 32-bit code; armv7 binaries run fine on it.
ARCHS = armv7

# TARGET = iphone:clang:<SDK version you downloaded>:<minimum iOS>
# Change 9.3 to match the .sdk folder you put in $THEOS/sdks (e.g. iPhoneOS9.3.sdk -> 9.3).
TARGET = iphone:clang:9.3:6.0

# The install scripts must be executable; zip files lose that, so set it before packaging.
_DS_CHMOD := $(shell chmod 755 layout/DEBIAN/postinst layout/DEBIAN/postrm 2>/dev/null)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DarkSix
DarkSix_FILES = Tweak.xm icon_core.c kb_core.c
DarkSix_FRAMEWORKS = UIKit QuartzCore CoreGraphics
# New Xcode compilers reject the old SDK's module.map file names; this silences that.
# Build in ARM mode, not Thumb. The new linker leaves off the Thumb marker on the startup
# function and iOS 6's loader then runs Thumb code as ARM and crashes (SIGILL).
DarkSix_CFLAGS = -Wno-deprecated-module-dot-map -Wno-unused-function -Wno-deprecated-declarations -Wno-error -marm -fobjc-exceptions
# The old SDK's system library stubs don't resolve with the new linker (memcpy, strncmp...).
# Let the phone resolve those at load time instead.
DarkSix_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk


