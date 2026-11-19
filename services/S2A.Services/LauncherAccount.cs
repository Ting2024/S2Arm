using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Ryujinx.HLE.HOS.Services.Account.Acc;

namespace S2A.Services
{
    // Explicit launcher selection, not a seed import. Immutable for a host session.
    // User 01 preserves the existing per-game account identity; other users must
    // carry their stable UID. Parsing must finish before persistent state is opened.
    public sealed class LauncherAccount
    {
        public string Id { get; }
        public string Name { get; }
        public string AccountUid { get; }
        public string StateRoot { get; }
        private static readonly UTF8Encoding StrictUtf8 = new(false, true);

        public LauncherAccount(string id, string name, string accountUid, string stateRoot)
        {
            if (id == null || !Regex.IsMatch(id, @"\A(?:0[1-9]|[1-9][0-9]{1,5})\z"))
                throw new ArgumentException("Invalid launcher user ID");
            if (string.IsNullOrWhiteSpace(name) || name != name.Trim() ||
                name.Any(c => c < 32 || (c >= 127 && c <= 159)) || StrictUtf8.GetByteCount(name) > 32)
                throw new ArgumentException("Invalid launcher user name");
            if (id == "01" ? accountUid != null :
                accountUid == null || !Regex.IsMatch(accountUid, @"\A[0-9a-f]{32}\z") ||
                accountUid == new string('0', 32) || accountUid == AccountManager.DefaultUserId.ToString())
                throw new ArgumentException("Invalid launcher account identity");
            if (string.IsNullOrEmpty(stateRoot) || !Path.IsPathFullyQualified(stateRoot))
                throw new ArgumentException("Invalid launcher state root");
            Id = id; Name = name; AccountUid = accountUid;
            StateRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(stateRoot));
        }

        internal static LauncherAccount Parse(string json)
        {
            if (json == null) return null;
            if (json.Length > 16384) throw new ArgumentException("Launcher account descriptor too large");
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            string[] fields = ["schema", "id", "name", "accountUid", "stateRoot"];
            if (root.ValueKind != JsonValueKind.Object) throw new ArgumentException("Invalid launcher account descriptor");
            var names = root.EnumerateObject().Select(p => p.Name).ToArray();
            if (names.Length != fields.Length || names.Distinct().Count() != fields.Length || fields.Except(names).Any() ||
                root.GetProperty("schema").GetInt32() != 1)
                throw new ArgumentException("Invalid launcher account descriptor");
            return new LauncherAccount(root.GetProperty("id").GetString(), root.GetProperty("name").GetString(),
                root.GetProperty("accountUid").GetString(), root.GetProperty("stateRoot").GetString());
        }

        internal void ValidateRoot(string stateRoot)
        {
            // Deliberately exact (including case); the launcher sends its canonical
            // root. Never silently accept a descriptor targeting another user root.
            string full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(stateRoot));
            if (!string.Equals(full, StateRoot, StringComparison.Ordinal))
                throw new ArgumentException("Launcher account does not match persistent state root");
            string current = Path.GetPathRoot(full);
            foreach (string part in full[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, part);
                if (new DirectoryInfo(current).LinkTarget != null)
                    throw new ArgumentException("Launcher state root must be canonical and contain no links");
            }
        }

        internal void Apply(AccountManager accounts)
        {
            if (Id == "01")
            {
                var existing = accounts.LastOpenedUser ?? throw new InvalidOperationException("Legacy account is unavailable");
                // Only an explicit launcher selection renames it, never a legacy boot.
                if (existing.Name != Name) accounts.SetUserName(existing.UserId, Name);
                accounts.SelectSessionUser(existing.UserId);
                return;
            }
            var uid = new UserId(AccountUid);
            var profile = accounts.GetAllUsers().FirstOrDefault(u => u.UserId == uid);
            if (profile == null)
                accounts.AddUser(Name, Ryujinx.Common.EmbeddedResources.Read("Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg"), uid);
            else if (profile.Name != Name)
                accounts.SetUserName(uid, Name); // Preserve avatar and all save ownership.
            accounts.SelectSessionUser(uid);
            if (accounts.LastOpenedUser?.UserId != uid)
                throw new InvalidOperationException("Launcher account selection did not take effect");
        }
    }
}
