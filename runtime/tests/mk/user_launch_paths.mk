# Path-only sub-contract; production account capability must not be inferred from it.
NATIVE_TEST_OWN += user_launch_paths
.PHONY: native-test-user_launch_paths
native-test-user_launch_paths:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_user_launch_paths runtime/tests/t_user_launch_paths.c runtime/src/launchctx.c -Wl,-U,_S2A_LauncherAccount_v1
	$(BUILD)/tests/t_user_launch_paths
TEST_TARGETS += native-test-user_launch_paths
