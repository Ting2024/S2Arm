NATIVE_TEST_OWN += user_launch_account
.PHONY: native-test-user_launch_account
native-test-user_launch_account:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_TEST_LAUNCH_ENV -o $(BUILD)/tests/t_user_launch_account runtime/tests/t_user_launch_account.c runtime/src/launchctx.c
	$(BUILD)/tests/t_user_launch_account
TEST_TARGETS += native-test-user_launch_account
