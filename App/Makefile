THEOS_OBJ_DIR_NAME := obj/app$(if $(filter 1,$(DEVICE_SMOKE)),-smoke,)

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := FridaLocal
FridaLocal_FILES := FridaLocalApp.swift ScriptLibrary.swift ServiceClient.swift ServiceViews.swift ReleaseCatalog.swift VersionListView.swift ../Shared/LocalFridaService.m
FridaLocal_FRAMEWORKS := SwiftUI UIKit UniformTypeIdentifiers
FridaLocal_CFLAGS := -fobjc-arc -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.theos/clang-cache
FridaLocal_SWIFTFLAGS := -module-cache-path $(THEOS_PROJECT_DIR)/.theos/modulecache -import-objc-header ../Shared/LocalFridaService.h
FridaLocal_LDFLAGS := -Wl,-weak_framework,SwiftUICore -Wl,-client_name,SwiftUI
FridaLocal_CODESIGN_FLAGS := -Idev.fridalocal.app -SEntitlements.plist
FridaLocal_RESOURCE_DIRS := Resources
FridaLocal_RESOURCE_FILES := ../examples/hello.js

ifeq ($(DEVICE_SMOKE),1)
FridaLocal_FILES += ../tests/DeviceSmoke.swift
FridaLocal_SWIFTFLAGS += -DFL_DEVICE_SMOKE
endif

include $(THEOS_MAKE_PATH)/application.mk
