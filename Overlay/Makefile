include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FridaLocalOverlay
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := SpringBoard

FridaLocalOverlay_FILES := ScriptOverlay.m ../Shared/LocalFridaService.m ../Shared/TerminalLog.m
FridaLocalOverlay_CFLAGS := -fobjc-arc -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/clang-cache
FridaLocalOverlay_FRAMEWORKS := Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
