THEOS_OBJ_DIR_NAME := obj/daemon

include $(THEOS)/makefiles/common.mk

TOOL_NAME := fridalocald fridalocald16
FRIDA_DEPS := $(THEOS_PROJECT_DIR)/.deps
FridaServerPrefix := $(THEOS_STAGING_DIR)/usr/libexec/fridalocal
fridalocald_FILES := main.m Runtime.m ReleaseAssets.m ../Shared/LocalFridaService.m
fridalocald_CFLAGS := -fobjc-arc -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/clang-cache -I$(FRIDA_DEPS)/core -DFL_PROTOCOL_MAJOR=17
fridalocald_FRAMEWORKS := Foundation CoreFoundation CoreGraphics UIKit Security SystemConfiguration
fridalocald_LIBRARIES := bsm dl m resolv roothide
fridalocald_LDFLAGS := $(FRIDA_DEPS)/core/libfrida-core.a
fridalocald_CODESIGN_FLAGS := -Idev.fridalocal.service -SEntitlements.plist
fridalocald_INSTALL_PATH := /usr/bin

fridalocald16_FILES := $(fridalocald_FILES)
fridalocald16_CFLAGS := -fobjc-arc -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/clang-cache -I$(FRIDA_DEPS)/core-16 -DFL_PROTOCOL_MAJOR=16
fridalocald16_FRAMEWORKS := $(fridalocald_FRAMEWORKS)
fridalocald16_LIBRARIES := $(fridalocald_LIBRARIES)
fridalocald16_LDFLAGS := $(FRIDA_DEPS)/core-16/libfrida-core.a
fridalocald16_CODESIGN_FLAGS := -Idev.fridalocal.service16 -SEntitlements.plist
fridalocald16_INSTALL_PATH := $(fridalocald_INSTALL_PATH)

include $(THEOS_MAKE_PATH)/tool.mk

before-all::
	@test -f "$(FRIDA_DEPS)/core/libfrida-core.a" && test -f "$(FRIDA_DEPS)/core-16/libfrida-core.a" || (echo 'Run make deps first.' >&2; exit 1)

internal-stage::
	install -d "$(THEOS_STAGING_DIR)/Library/LaunchDaemons" "$(FridaServerPrefix)/sbin" "$(FridaServerPrefix)/lib/frida-1.0"
	install -m 644 dev.fridalocal.service.plist dev.fridalocal.service16.plist "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/"
	install -m 755 "$(FRIDA_DEPS)/server/var/jb/usr/sbin/frida-server" "$(FridaServerPrefix)/sbin/"
	install -m 755 "$(FRIDA_DEPS)/server/var/jb/usr/lib/frida-1.0/frida-agent.dylib" "$(FridaServerPrefix)/lib/frida-1.0/"
