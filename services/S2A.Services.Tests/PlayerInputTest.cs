using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.SystemState;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private static readonly object PlayerFixtureLock = new();
        private static PlayerInputFrame _playerFixture;
        private static int _playerFixtureAvailable, _playerFixtureCalls;

        [UnmanagedCallersOnly]
        private static int ReadPlayerFixture(PlayerInputFrame* frame, uint capacity)
        {
            lock (PlayerFixtureLock)
            {
                Interlocked.Increment(ref _playerFixtureCalls);
                if (capacity != sizeof(PlayerInputFrame) || _playerFixtureAvailable == 0) return 0;
                *frame = _playerFixture;
                return 1;
            }
        }

        [SoloTest("--input-four-players")]
        private static int FourPlayerInputTest()
        {
            string root = Path.Combine(Directory.GetCurrentDirectory(), "build", "player-input-" + Guid.NewGuid().ToString("N"));
            string game = Path.Combine(root, "game"), state = Path.Combine(root, "state");
            Directory.CreateDirectory(game);
            int checks = 0, failures = 0;
            void Expect(bool ok, string label)
            {
                Interlocked.Increment(ref checks); if (!ok) { Interlocked.Increment(ref failures); Console.WriteLine("FAIL: " + label); }
            }
            try
            {
                FakeNative.Install(); AttachTestTimeZone(game);
                Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state,
                    new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, new HostUi()));
                var device = Host.Device;
                Expect(sizeof(PlayerInputFrame) == 96 && sizeof(PlayerInputSlot) == 20, "native ABI sizes");
                Expect(Marshal.OffsetOf<PlayerInputFrame>(nameof(PlayerInputFrame.Fourth)).ToInt32() == 76, "native ABI fourth offset");
                PlayerInputFrame frame = new() { Version = 1, Bytes = 96, ConnectedMask = 15, Active = 1,
                    First = new() { Buttons = 1, LeftX = 1000, RightY = -1000 },
                    Second = new() { Buttons = 2, LeftX = 2000, RightY = -2000 },
                    Third = new() { Buttons = 4, LeftX = 3000, RightY = -3000 },
                    Fourth = new() { Buttons = 8, LeftX = 4000, RightY = -4000 } };
                var players = new PlayerInput();
                void CheckFrame(uint mask, bool neutral)
                {
                    for (int i = 0; i < 4; i++)
                    {
                        ref var npad = ref device.Hid.SharedMemory.Npads[i].InternalState;
                        ref var actual = ref npad.FullKey.GetCurrentEntryRef();
                        bool connected = (mask & (1u << i)) != 0;
                        Expect((npad.StyleSet != 0) == connected, $"player {i + 1} connection");
                        Expect((ulong)actual.Buttons == (connected && !neutral ? 1ul << i : 0), $"player {i + 1} independent buttons");
                        Expect(actual.AnalogStickL.X == (connected && !neutral ? (i + 1) * 1000 : 0), $"player {i + 1} independent left stick");
                        Expect(actual.AnalogStickR.Y == (connected && !neutral ? -(i + 1) * 1000 : 0), $"player {i + 1} independent right stick");
                    }
                }
                players.Commit(device, frame, true, false); CheckFrame(15, false);
                frame.ConnectedMask = 10; // 1P/3P disconnected; no compacting into holes.
                players.Commit(device, frame, true, false); CheckFrame(10, false);
                frame.Active = 0; players.Commit(device, frame, true, false); CheckFrame(10, true);
                frame.Active = 1; players.Commit(device, frame, true, true); CheckFrame(10, true);
                players.Commit(device, frame, true, false); CheckFrame(10, false);
                frame.ConnectedMask = 15; players.Commit(device, frame, true, false); CheckFrame(15, false);
                foreach (int kind in new[] { 0, 1, 2, 3, 4 })
                {
                    var bad = frame;
                    if (kind == 0) bad.Version = 2;
                    if (kind == 1) bad.Bytes = 95;
                    if (kind == 2) bad.ConnectedMask = 16;
                    if (kind == 3) bad.Active = 2;
                    players.Commit(device, bad, kind != 4, false); CheckFrame(0, true);
                }
                // Respect the guest's supported player set without moving input
                // from the rejected player into an allowed slot.
                device.Hid.Npads.SetSupportedPlayer(PlayerIndex.Player2, false);
                players.Commit(device, frame, true, false); CheckFrame(13, false);
                device.Hid.Npads.SetSupportedPlayer(PlayerIndex.Player2, true);
                players.Commit(device, frame, true, false); CheckFrame(15, false);
                frame.First.Buttons = 0xffff0001; frame.First.LeftX = int.MaxValue; frame.First.RightY = int.MinValue;
                players.Commit(device, frame, true, false);
                ref var clamped = ref device.Hid.SharedMemory.Npads[0].InternalState.FullKey.GetCurrentEntryRef();
                Expect(clamped.AnalogStickL.X == 32767 && clamped.AnalogStickR.Y == -32767, "stick clamp");
                Expect(((ulong)clamped.Buttons & 0xffff) == 1, "unknown button bits stripped");
                frame.First = new() { Buttons = 1, LeftX = 1000, RightY = -1000 };
                // Vary every slot independently over many commits: game-facing
                // memory, not the planner's output, is the oracle.
                for (int sample = 0; sample < 64; sample++)
                {
                    frame.ConnectedMask = (uint)(sample & 15);
                    players.Commit(device, frame, true, false);
                    CheckFrame(frame.ConnectedMask, false);
                }
                frame.ConnectedMask = 15;
                // No per-frame allocation after connection/configuration warmup.
                for (int i = 0; i < 100; i++) players.Commit(device, frame, true, false);
                long before = GC.GetAllocatedBytesForCurrentThread();
                for (int i = 0; i < 1000; i++) players.Commit(device, frame, true, false);
                long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
                Expect(allocated == 0, "steady state allocates zero bytes");

                // Actual production HID thread calls the native ABI and writes
                // shared memory. TouchHook observes on that same owning thread.
                _playerFixture = frame; _playerFixtureAvailable = 1; _playerFixtureCalls = 0;
                InputPump.PlayerReader = &ReadPlayerFixture;
                using var committed = new ManualResetEventSlim(false);
                InputPump.TouchHook = _ => { CheckFrame(15, false); committed.Set(); };
                InputPump.Start(device);
                Expect(committed.Wait(3000), "real pump committed four slots");
                var applet = new Ryujinx.HLE.HOS.Applets.ControllerAppletUIArgs {
                    PlayerCountMin = 4, PlayerCountMax = 4,
                    SupportedPlayers = new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3, PlayerIndex.Player4 },
                    SupportedStyles = ControllerType.ProController, IsDocked = false };
                Expect(device.UIHandler.DisplayMessageDialog(applet), "four physical slots satisfy applet");
                applet.PlayerCountMin = 5; applet.PlayerCountMax = 8;
                Expect(!device.UIHandler.DisplayMessageDialog(applet), "applet cannot fabricate fifth player");
                applet.PlayerCountMin = 4; applet.PlayerCountMax = 4;
                applet.SupportedPlayers = new[] { PlayerIndex.Player1, PlayerIndex.Player2 };
                Expect(!device.UIHandler.DisplayMessageDialog(applet), "applet only counts allowed player IDs");
                InputPump.SetPads(device, 2); // old applet path must not enable mirror mode.
                InputPump.Stop();
                Expect(_playerFixtureCalls > 0 && InputPump.PlayerReader == null, "owned reader reset after join");
                Expect(InputPump.Pads <= 2, "legacy topology reset after stop");

                // Missing sample never falls back to stale primary/mirrored input.
                _playerFixtureAvailable = 0;
                InputPump.PlayerReader = &ReadPlayerFixture;
                committed.Reset();
                InputPump.TouchHook = _ => { CheckFrame(0, true); committed.Set(); };
                InputPump.Start(device); Expect(committed.Wait(3000), "unavailable reader releases all slots");
                InputPump.Stop();
                // Reuse the same process/device: no previous player's state retained.
                frame.ConnectedMask = 8;
                _playerFixture = frame; _playerFixtureAvailable = 1;
                InputPump.PlayerReader = &ReadPlayerFixture;
                committed.Reset();
                InputPump.TouchHook = _ => { CheckFrame(8, false); committed.Set(); };
                InputPump.Start(device); Expect(committed.Wait(3000), "restart keeps only connected fourth player");
                InputPump.Stop();
                // Optional independently compiled C producer. This exercises the
                // actual C mutex/POD transport -> unmanaged ABI -> HID thread ->
                // game-visible shared memory, rather than two managed structs.
                bool nativeBridge = false;
                string bridgePath = Environment.GetEnvironmentVariable("S2A_PLAYER_INPUT_TEST_BRIDGE");
                if (!string.IsNullOrEmpty(bridgePath))
                {
                    nint library = NativeLibrary.Load(Path.GetFullPath(bridgePath));
                    var begin = (delegate* unmanaged<int>)NativeLibrary.GetExport(library, "s2a_test_player_begin");   // 平台例外：单测按 S2A_PLAYER_INPUT_TEST_BRIDGE 临时加载独立编译的 C 试验桥接库，非宿主生产导出
                    var publish = (delegate* unmanaged<uint, uint, int>)NativeLibrary.GetExport(library, "s2a_test_player_publish");   // 平台例外：同上（单测 C 试验桥接库导出）
                    var read = (delegate* unmanaged<PlayerInputFrame*, uint, int>)NativeLibrary.GetExport(library, "s2a_test_player_read");   // 平台例外：同上（单测 C 试验桥接库导出）
                    var stop = (delegate* unmanaged<void>)NativeLibrary.GetExport(library, "s2a_test_player_stop");   // 平台例外：同上（单测 C 试验桥接库导出）
                    var end = (delegate* unmanaged<void>)NativeLibrary.GetExport(library, "s2a_test_player_end");   // 平台例外：同上（单测 C 试验桥接库导出）
                    bool began = false;
                    try
                    {
                        began = begin() == 1; Expect(began, "C transport initialized");
                        if (began)
                        {
                            foreach (uint mask in new uint[] { 15, 10, 8 })
                            {
                                Expect(publish(mask, 1) == 1, "C producer publishes four-slot frame");
                                InputPump.PlayerReader = read;
                                committed.Reset();
                                InputPump.TouchHook = _ => { CheckFrame(mask, false); committed.Set(); };
                                InputPump.Start(device); Expect(committed.Wait(3000), "C frame reaches real HID thread");
                                InputPump.Stop();
                            }
                            Expect(publish(15, 0) == 1, "C inactive snapshot");
                            InputPump.PlayerReader = read; committed.Reset();
                            InputPump.TouchHook = _ => { CheckFrame(15, true); committed.Set(); };
                            InputPump.Start(device); Expect(committed.Wait(3000), "native focus release reaches all players");
                            InputPump.Stop();
                            stop();
                            InputPump.PlayerReader = read; committed.Reset();
                            InputPump.TouchHook = _ => { CheckFrame(0, true); committed.Set(); };
                            InputPump.Start(device); Expect(committed.Wait(3000), "native stop cannot replay old frame");
                            InputPump.Stop();
                            nativeBridge = true;
                        }
                    }
                    finally
                    {
                        // Join before unloading function pointers or destroying
                        // the C mutex. The production stop contract is identical.
                        InputPump.Stop();
                        if (began) end();
                        NativeLibrary.Free(library);
                    }
                }
                Console.WriteLine($"Independent player HID: checks={checks}, failures={failures}, steady-state-bytes={allocated}, native-bridge={nativeBridge}; synthetic only");
                return failures == 0 ? 0 : 1;
            }
            finally
            {
                InputPump.Stop(); InputPump.TouchHook = null;
                if (Host.Device != null) { Host.ShutdownSessionServices(); Host.FinishShutdownSession(); }
                Directory.Delete(root, true);
            }
        }
    }
}
