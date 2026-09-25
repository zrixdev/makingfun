TARGET := iphone:clang:14.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MLBBESP
MLBBESP_FILES = Tweak.m
MLBBESP_FRAMEWORKS = UIKit CoreGraphics Foundation
MLBBESP_CFLAGS = -fobjc-arc -Wno-unused-variable
MLBBESP_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
