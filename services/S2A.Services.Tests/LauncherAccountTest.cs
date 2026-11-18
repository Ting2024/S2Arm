using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Ryujinx.HLE.HOS.Services.Account.Acc;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--launcher-account-contract")]
        private static int LauncherAccountContractTest()
        {
            string root = Path.Combine(Directory.GetCurrentDirectory(), "build", "account-contract-" + Guid.NewGuid().ToString("N"));
            string state = Path.Combine(root, "state");
            Directory.CreateDirectory(root);
            try
            {
                int failures = 0;
                void Expect(bool ok) { if (!ok) failures++; }
                string uid = "1234567890abcdef1234567890abcdef";
                string Descriptor(string id = "02", string name = "Fixture", string account = null) =>
                    JsonSerializer.Serialize(new { schema = 1, id, name, accountUid = account ?? uid, stateRoot = state });
                var selected = LauncherAccount.Parse(Descriptor());
                selected.ValidateRoot(state);
                Expect(selected.Id == "02" && selected.AccountUid == uid && selected.Name == "Fixture");
                Expect(!Directory.Exists(state)); // Parsing never creates persistent state.
                Expect(LauncherAccount.Parse(null) == null);
                delegate* unmanaged<int> capability = &Exports.LauncherAccountVersion;
                Expect(capability() == 1);
                void Reject(Action action)
                {
                    try { action(); failures++; }
                    catch (Exception error) when (error is ArgumentException || error is JsonException || error is InvalidOperationException) { }
                }
                foreach (string bad in new[] { "", "null", "{}", "{\"schema\":1,\"schema\":1}", Descriptor(id: "../02"),
                    Descriptor(id: "01"), Descriptor(name: "bad\nname"), Descriptor(name: new string('你', 11)),
                    Descriptor(account: new string('0', 32)), Descriptor(account: AccountManager.DefaultUserId.ToString()) })
                    Reject(() => LauncherAccount.Parse(bad));
                Reject(() => new LauncherAccount("02", "\ud800", uid, state));
                Reject(() => new LauncherAccount("02", "Fixture", uid, "relative"));
                Reject(() => selected.ValidateRoot(Path.Combine(root, "other")));
                Directory.CreateDirectory(state);
                string link = Path.Combine(root, "alias");
                Directory.CreateSymbolicLink(link, state);
                Reject(() => new LauncherAccount("02", "Fixture", uid, link).ValidateRoot(link));
                string duplicate = Descriptor().Replace("\"schema\":1", "\"schema\":1,\"schema\":1");
                Reject(() => LauncherAccount.Parse(duplicate));
                var legacy = new LauncherAccount("01", "Fixture 1", null, state);
                legacy.ValidateRoot(state);
                Expect(legacy.AccountUid == null);
                Console.WriteLine($"Launcher account descriptor: validation, root binding, legacy preservation; failures={failures}");
                return failures == 0 ? 0 : 1;
            }
            finally { Directory.Delete(root, true); }
        }

        [SoloTest("--launcher-account-boot")]
        private static int LauncherAccountBootTest() => LauncherAccountBoot(false);

        [SoloTest("--launcher-account-platform")]
        private static int LauncherAccountPlatformTest() => LauncherAccountBoot(true);

        private static int LauncherAccountBoot(bool platform)
        {
            string root = Path.Combine(Directory.GetCurrentDirectory(), "build", "account-boot-" + Guid.NewGuid().ToString("N"));
            string state = Path.Combine(root, "state"), game = Path.Combine(root, "game");
            string old = Environment.GetEnvironmentVariable("S2A_SESSION_USER");
            string oldSeed = Environment.GetEnvironmentVariable("S2A_SAVE_DIR");
            Directory.CreateDirectory(game);
            string uid = "1234567890abcdef1234567890abcdef";
            try
            {
                FakeNative.Install();
                AttachTestTimeZone(game);
                var account = new LauncherAccount("02", "Fixture Second", uid, state);
                string Descriptor(string path) => JsonSerializer.Serialize(new { schema = 1, id = "02", name = "Fixture Second", accountUid = uid, stateRoot = path });
                Ryujinx.Audio.Backends.Dummy.DummyHardwareDeviceDriver Audio() => new();
                Environment.SetEnvironmentVariable("S2A_SAVE_DIR", null);
                // A mismatched account descriptor must fail before even mkdir(state).
                Environment.SetEnvironmentVariable("S2A_SESSION_USER", Descriptor(Path.Combine(root, "other")));
                bool rejected = false;
                try { Host.Boot(new StubRenderer(), Audio(), state); }
                catch (ArgumentException) { rejected = true; }
                bool untouched = !Directory.Exists(state);
                Environment.SetEnvironmentVariable("S2A_SESSION_USER", Descriptor(state));
                Environment.SetEnvironmentVariable("S2A_SAVE_DIR", Path.Combine(root, "seed"));
                bool seedRejected = false;
                try { Host.Boot(new StubRenderer(), Audio(), state); }
                catch (ArgumentException) { seedRejected = true; }
                untouched &= !Directory.Exists(state);
                Environment.SetEnvironmentVariable("S2A_SAVE_DIR", null);
                HostConfiguration config = null;
                if (platform)
                {
                    // Platform-owned configuration must ignore hostile inherited env.
                    Environment.SetEnvironmentVariable("S2A_SESSION_USER", "not-json");
                    config = new HostConfiguration(game, state, Ryujinx.HLE.HOS.SystemState.SystemLanguage.AmericanEnglish,
                        Ryujinx.HLE.HOS.SystemState.RegionCode.USA, "UTC", false, new HostUi(), account: account);
                }
                Host.Boot(new StubRenderer(), Audio(), state, config);
                var selected = Host.Device.System.AccountManager.LastOpenedUser;
                bool opened = selected.UserId.ToString() == uid && selected.Name == "Fixture Second";
                string sentinel = Path.Combine(state, "independent-progress.fixture");
                File.WriteAllText(sentinel, "isolated-progress");
                Host.ShutdownSessionServices(); Host.FinishShutdownSession();
                // Once progress exists, invalid input must not rewrite profiles,
                // seed data, or any other persistent byte before it is rejected.
                var savedBytes = Directory.GetFiles(state, "*", SearchOption.AllDirectories)
                    .ToDictionary(path => path, File.ReadAllBytes);
                string validEnvironment = Environment.GetEnvironmentVariable("S2A_SESSION_USER");
                bool existingUntouched = true;
                foreach (string invalid in new[] { "not-json", "{}", "null", Descriptor(Path.Combine(root, "other")) })
                {
                    Environment.SetEnvironmentVariable("S2A_SESSION_USER", invalid);
                    bool refused = false;
                    try { Host.Boot(new StubRenderer(), Audio(), state); }
                    catch (Exception error) when (error is ArgumentException || error is JsonException) { refused = true; }
                    existingUntouched &= refused && Host.Device == null &&
                        Directory.GetFiles(state, "*", SearchOption.AllDirectories).Length == savedBytes.Count &&
                        savedBytes.All(pair => File.Exists(pair.Key) && File.ReadAllBytes(pair.Key).SequenceEqual(pair.Value));
                    if (Host.Device != null) { Host.ShutdownSessionServices(); Host.FinishShutdownSession(); }
                }
                Environment.SetEnvironmentVariable("S2A_SESSION_USER", validEnvironment);
                Host.Boot(new StubRenderer(), Audio(), state, config);
                bool reopened = Host.Device.System.AccountManager.LastOpenedUser.UserId.ToString() == uid &&
                    Host.Device.System.AccountManager.GetAllUsers().Count(u => u.UserId.ToString() == uid) == 1 &&
                    File.ReadAllText(sentinel) == "isolated-progress";
                Host.ShutdownSessionServices(); Host.FinishShutdownSession();
                bool ok = rejected && seedRejected && untouched && existingUntouched && opened && reopened;
                Console.WriteLine($"Launcher account real boot: platform={platform}, reject-before-write={rejected && seedRejected && untouched}, invalid-preserves-existing-bytes={existingUntouched}, selected={opened}, reopen-preserves-data={reopened}");
                return ok ? 0 : 1;
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_SESSION_USER", old);
                Environment.SetEnvironmentVariable("S2A_SAVE_DIR", oldSeed);
                if (Host.Device != null) { Host.ShutdownSessionServices(); Host.FinishShutdownSession(); }
                Directory.Delete(root, true);
            }
        }

        [SoloTest("--launcher-account-ipc", Booted = true)]
        private static void LauncherAccountIpcTest()
        {
            var accounts = Host.Device.System.AccountManager;
            var original = accounts.LastOpenedUser;
            byte[] avatar = original.Image.ToArray();
            string state = Ryujinx.Common.Configuration.AppDataManager.BaseDirPath;
            string uid = "1234567890abcdef1234567890abcdef";
            int count = accounts.GetAllUsers().Count();
            var selection = new LauncherAccount("02", "Fixture Second", uid, state);
            selection.Apply(accounts);
            var selected = accounts.LastOpenedUser;
            Check("Launcher selected account UID", "True", (selected.UserId.ToString() == uid).ToString());
            Check("Launcher account name stored in account manager", "True", (selected.Name == "Fixture Second").ToString());
            Check("Creating launcher account retains default", "True", (accounts.GetAllUsers().Count() == count + 1 &&
                accounts.GetAllUsers().Any(u => u.UserId == original.UserId)).ToString());
            accounts.SetUserImage(selected.UserId, new byte[] { 3, 4, 5 });
            new LauncherAccount("02", "Fixture Renamed", uid, state).Apply(accounts);
            Check("Rename preserves UID, avatar and account count", "True", (accounts.LastOpenedUser.UserId == selected.UserId &&
                accounts.LastOpenedUser.Name == "Fixture Renamed" && accounts.LastOpenedUser.Image.SequenceEqual(new byte[] { 3, 4, 5 }) &&
                accounts.GetAllUsers().Count() == count + 1).ToString());
            accounts.OpenUser(original.UserId);
            selection.Apply(accounts);
            Check("Reopen existing selected account", "True", (accounts.LastOpenedUser.UserId == selected.UserId).ToString());

            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Regs[1];
            Msg init = Msg.Cmif(0, Bytes(0L)); init.SendPid = true; Call(sm, init);
            Reply service = Call(sm, Msg.Cmif(1, Name8("acc:u0")));
            uint acc = service.Move[0];
            using var bytes = new MemoryStream();
            selected.UserId.Write(new BinaryWriter(bytes));
            byte[] expected = bytes.ToArray();
            foreach (uint command in new uint[] { 51, 52 })
            {
                Reply result = Call(acc, Msg.Cmif(command, new byte[8]));
                bool ok = result.Result == 0 && new ReadOnlySpan<byte>(result.Data, 16).SequenceEqual(expected);
                Check($"acc:u0 {command} uses explicit launcher selection", "True", ok.ToString());
            }
            // Read through the actual guest profile service, not the host object.
            Reply profileReply = Call(acc, Msg.Cmif(5, expected));
            bool profileOpened = profileReply.Result == 0 && profileReply.Move.Count > 0;
            Check("acc:u0 opens selected guest profile", "True", profileOpened.ToString());
            if (profileOpened)
            {
                uint profile = profileReply.Move[0];
                void CheckGuestProfile(string name)
                {
                    Reply result = Call(profile, Msg.Cmif(1));
                    bool ok = result.Result == 0 && new ReadOnlySpan<byte>(result.Data, 16).SequenceEqual(expected) &&
                        Encoding.UTF8.GetString(new ReadOnlySpan<byte>(result.Data + 24, 32)).TrimEnd('\0') == name;
                    Check("Guest ProfileBase returns selected UID and current nickname", "True", ok.ToString());
                }
                CheckGuestProfile("Fixture Second");
                new LauncherAccount("02", "测试玩家二", uid, state).Apply(accounts);
                CheckGuestProfile("测试玩家二");
                FakeNative.HandleClose(profile);
            }
            FakeNative.HandleClose(acc); FakeNative.HandleClose(sm);
            // Default launcher user must keep the existing non-default UID.
            new LauncherAccount("01", "Fixture Legacy", null, state).Apply(accounts);
            Check("Launcher 01 preserves existing per-game UID", "True", (accounts.LastOpenedUser.UserId == selected.UserId).ToString());
            Check("Unselected original account is untouched", "True", (original.Image.SequenceEqual(avatar)).ToString());
        }
    }
}
