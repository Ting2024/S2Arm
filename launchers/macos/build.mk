# Mac game window/input shell; launcher preparation opts in with a private BUILD.
ifeq ($(S2A_MAC_FRONTEND),1)
CFLAGS += -fobjc-arc -Iruntime/src
# 玩家入口：自动玩家缺省关（tests/autoplay/ap_default.h）
CFLAGS += -DS2A_MAC_FRONTEND=1
HOST_SRCS += macos/heartbeat_mac.c macos/front_mac.m macos/controllers/S2AControllerInput.m macos/joycon_imu.m macos/hid_pad.m macos/input_guide.m macos/controller_view.m macos/textinput_mac.m
HOST_SRCS += macos/ns2_controller.c $(wildcard runtime/ns2pro/*.c) runtime/ns2pro/NS2Transport.m
CFLAGS += -Iruntime/ns2pro/include -DNS2_SCAN_SECONDS=60
HOST_LIBS += -framework AppKit -framework CoreGraphics -framework GameController -framework CoreHaptics -framework CoreBluetooth -framework IOKit
NS2_HELPER := $(BUILD)/S2ArmNS2Connection
NS2_HELPER_SRCS := macos/ns2_connection_helper.m macos/ns2_parent_watch.c runtime/ns2pro/NS2Transport.m $(wildcard runtime/ns2pro/*.c)
$(NS2_HELPER): $(NS2_HELPER_SRCS) $(wildcard runtime/ns2pro/include/*.h) macos/ns2_relay.h macos/ns2_parent_watch.h
	$(CC) $(CFLAGS) -Iruntime/ns2pro/include -DNS2_SCAN_SECONDS=60 $(NS2_HELPER_SRCS) -framework Foundation -framework CoreBluetooth -framework IOBluetooth -o $@
host: $(NS2_HELPER)
$(BUILD)/s2arm-host: launchers/macos/build.mk macos/input_settings.inc macos/input_settings_shortcut.h
endif

# Migration candidate only until legacy JSON settings and feedback ABI are wired.
# The production default stays unchanged; no four-player capability is fabricated.
ifeq ($(S2A_MAC_FRONTEND):$(S2A_MNG_INPUT),1:1)
CFLAGS += -DS2A_MNG_INPUT=1
HOST_SRCS += macos/controllers/mng/gamepad.m macos/controllers/mng/gamepad_feedback.m macos/controllers/mng/motion_fusion.c
HOST_SRCS += macos/controllers/mng_adapter.m macos/controllers/mng_ownership.c macos/controllers/mng_settings.m macos/controllers/mng_host.m
HOST_LIBS += -framework CoreHaptics
$(BUILD)/s2arm-host: $(wildcard macos/controllers/mng/*.h macos/controllers/mng/*.inc) macos/controllers/mng_adapter.h macos/controllers/mng_settings.h
endif
