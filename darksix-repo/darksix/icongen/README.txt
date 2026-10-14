DarkSix - experimental dark mode tweak for iOS 6 (iPhone 5)

BUILD (on the Mac, after installing Theos and putting an SDK in $THEOS/sdks):
  1. Open Makefile and set the SDK version in TARGET to match your .sdk folder name.
  2. In this folder run:   make package
  3. The .deb appears in ./packages/

INSTALL:
  Copy the .deb to the phone (iFile or scp) and install it (tap it in iFile,
  or run:  dpkg -i file.deb ), then respring.
  Or, with SSH set up:  THEOS_DEVICE_IP=<phone ip> make package install

APPS AFFECTED: edit DarkSix.plist (Bundles list). Currently Settings, Messages, Music (not Now Playing),
Mail, Contacts, Phone. Remove an app from the list if it breaks.

UNINSTALL: delete DarkSix.dylib and DarkSix.plist from
/Library/MobileSubstrate/DynamicLibraries/ , or  dpkg -r com.example.darksix
Safe Mode (hold Volume Up during respring) disables tweaks if an app crashes.
