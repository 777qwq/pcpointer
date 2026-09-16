export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:26.5:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PCPointer PCPointerBB PCPointerBB2 PCPointerBB3
PCPointer_FILES = PCPointer.x
PCPointer_CFLAGS = -fobjc-arc
PCPointer_FRAMEWORKS = UIKit
PCPointer_LDFLAGS = -undefined dynamic_lookup
PCPointerBB_FILES = PCPointerBB.x
PCPointerBB_CFLAGS = -fobjc-arc
PCPointerBB_LDFLAGS = -undefined dynamic_lookup
PCPointerBB2_FILES = PCPointerBB2.x
PCPointerBB2_CFLAGS = -fobjc-arc
PCPointerBB2_LDFLAGS = -undefined dynamic_lookup
PCPointerBB3_FILES = PCPointerBB3.x
PCPointerBB3_CFLAGS = -fobjc-arc
PCPointerBB3_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
