# Shared resources stay shared when a user's writable docs are isolated.
NATIVE_TEST_OWN += user_import_routing
.PHONY: native-test-user_import_routing
native-test-user_import_routing:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_user_import_routing runtime/tests/t_user_import_routing.c runtime/src/pack_apply.c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_user_import_routing
TEST_TARGETS += native-test-user_import_routing
