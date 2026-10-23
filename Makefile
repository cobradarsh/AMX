TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AMScreen
AMScreen_FILES = Tweak.x AMSScreenWindow.m
AMScreen_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AMScreen_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
