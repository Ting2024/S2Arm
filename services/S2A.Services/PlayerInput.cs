using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Services.Hid;

namespace S2A.Services
{
    // Keep in sync with runtime/include/s2a_player_input.h. One coherent sample,
    // one HID writer, no platform callbacks/objects on the service thread.
    [StructLayout(LayoutKind.Sequential)]
    internal struct PlayerInputSlot
    {
        public uint Buttons;
        public int LeftX, LeftY, RightX, RightY;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PlayerInputFrame
    {
        public uint Version, Bytes, ConnectedMask, Active;
        public PlayerInputSlot First, Second, Third, Fourth;
    }

    internal sealed class PlayerInput
    {
        internal const int PlayerCount = 4;
        private readonly List<GamepadInput> _states = new(PlayerCount);
        private uint _configuredMask = uint.MaxValue;
        internal uint ConnectedMask { get; private set; }

        internal static bool Valid(in PlayerInputFrame frame) =>
            frame.Version == 1 && frame.Bytes == 96 && (frame.ConnectedMask & ~15u) == 0 && frame.Active <= 1;

        internal void Commit(Switch device, in PlayerInputFrame frame, bool available, bool textInput)
        {
            uint mask = available && Valid(frame) ? frame.ConnectedMask : 0;
            // Config is changed only on real topology changes. Focus loss/text
            // input release buttons while preserving the user's player slots.
            if (mask != _configuredMask)
            {
                Span<ControllerConfig> config = stackalloc ControllerConfig[4];
                int count = 0;
                for (int i = 0; i < 4; i++)
                    if ((mask & (1u << i)) != 0)
                        config[count++] = new ControllerConfig { Player = (PlayerIndex)i, Type = ControllerType.ProController };
                lock (device.Hid.Npads.RumbleSyncRoot) device.Hid.Npads.Configure(config[..count]);
                _configuredMask = mask;
            }
            ConnectedMask = mask;
            _states.Clear();
            for (int i = 0; i < 4; i++)
            {
                if ((mask & (1u << i)) == 0) continue;
                PlayerInputSlot slot = i switch { 0 => frame.First, 1 => frame.Second, 2 => frame.Third, _ => frame.Fourth };
                GamepadInput input = new() { PlayerId = (PlayerIndex)i };
                if (frame.Active == 1 && !textInput)
                {
                    input.Buttons = (ControllerKeys)(slot.Buttons & 0xffffu);
                    input.LStick.Dx = Math.Clamp(slot.LeftX, -32767, 32767);
                    input.LStick.Dy = Math.Clamp(slot.LeftY, -32767, 32767);
                    input.RStick.Dx = Math.Clamp(slot.RightX, -32767, 32767);
                    input.RStick.Dy = Math.Clamp(slot.RightY, -32767, 32767);
                    input.Buttons |= device.Hid.UpdateStickButtons(input.LStick, input.RStick);
                }
                _states.Add(input);
            }
            // NpadDevices remaps styles according to the guest's declarations
            // and writes disconnected entries for absent players, including 1P.
            device.Hid.Npads.Update(_states);
        }
    }
}
