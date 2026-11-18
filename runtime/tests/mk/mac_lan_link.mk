# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-mac_lan_link
native-test-mac_lan_link:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -fobjc-arc -o $(BUILD)/tests/t_mac_lan_link runtime/tests/t_mac_lan_link.m ios/ldn_lan.m macos/lan_permission.m runtime/src/lan_elect.c -framework Foundation -framework AppKit
	$(BUILD)/tests/t_mac_lan_link
TEST_TARGETS += native-test-mac_lan_link
endif
