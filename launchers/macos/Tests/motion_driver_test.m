// Test the actual receive/ACK state machine without opening any hardware.
#import <Foundation/Foundation.h>
#import "../../../macos/controllers/include/S2AControllerInput.h"
#include <assert.h>
@interface S2AControllerInput (MotionTest)
- (void)receive:(uint8_t *)report size:(CFIndex)size;
- (void)detach;
@end
static void submitted(S2AControllerInput *input) {
    // Model a successfully submitted output report, never create a HID device.
    [input setValue:@YES forKey:@"imuPending"];
    [input setValue:@YES forKey:@"imuAttempted"];
}
int main(void) {
    @autoreleasepool {
        S2AControllerInput *input = [S2AControllerInput new];
        uint8_t report[49] = {0x30}, ack[15] = {0x21};
        report[38] = 16; report[44] = 64;
        ack[13] = 0x80; ack[14] = 0x40;
        S2AControllerMotion motion;
        input.motionEnabled = YES;
        [input receive:report size:49];
        assert(![input readMotion:&motion]); // No enable ACK yet.
        submitted(input);
        [input receive:ack size:14];
        [input receive:report size:49];
        assert(![input readMotion:&motion]); // Short ACK does not enable.
        [input receive:ack size:15];
        assert(![input readMotion:&motion]); // ACK is not a sensor sample.
        [input receive:report size:49];
        assert([input readMotion:&motion]);
        assert(motion.acceleration[0] == 1 && motion.gyro[0] == 1000);
        uint64_t timestamp = motion.timestampUs;
        assert([input readMotion:&motion] && motion.timestampUs == timestamp);
        [NSThread sleepForTimeInterval:0.27];
        assert(![input readMotion:&motion] && motion.timestampUs == 0);
        [input receive:report size:49];
        assert([input readMotion:&motion]);
        input.motionEnabled = NO;
        assert(![input readMotion:&motion]);
        submitted(input); // Disable was sent; user enables again before its ACK.
        input.motionEnabled = YES;
        [input receive:report size:49];
        assert(![input readMotion:&motion]);
        [input receive:ack size:15]; // ACK must resolve disable, not current intent.
        [input receive:report size:49];
        assert(![input readMotion:&motion]);
        submitted(input);
        ack[13] = 0; [input receive:ack size:15];
        [input receive:report size:49];
        assert(![input readMotion:&motion]); // Rejected command never admits data.
        submitted(input); ack[13] = 0x80; [input receive:ack size:15];
        [input receive:report size:49]; assert([input readMotion:&motion]);
        [input detach]; assert(![input readMotion:&motion]);
        [input receive:ack size:15]; // Unsolicited ACK after disconnect ignored.
        [input receive:report size:49]; assert(![input readMotion:&motion]);
        puts("NS Pro motion: ACK, rejection, intent race, freshness and detach passed");
    }
}
