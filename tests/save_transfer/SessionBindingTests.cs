using System.Text.Json.Nodes;

namespace S2A.Services;

public static partial class SaveTransfer
{
    public static void TestSessionBinding()
    {
        string temp = Path.Combine(Path.GetTempPath(), "s2arm-session-save-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        // Canonicalize /var aliases just as the native launch context does.
        temp = Path.GetFullPath(temp);
        string canonical = Path.GetPathRoot(temp)!;
        foreach (string part in temp[canonical.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            var directory = new DirectoryInfo(Path.Combine(canonical, part));
            canonical = directory.ResolveLinkTarget(true)?.FullName ?? directory.FullName;
        }
        temp = canonical;
        string root = Path.Combine(temp, "user02", "ryujinx"), work = Path.Combine(temp, "user02", "save-transfer");
        string id = "0100000000000001", uid = new string('a', 32);
        string[] keys = ["S2A_SESSION_USER", "S2A_RYU_DATA", "S2A_LAUNCH_GAME_ID"];
        var old = keys.Select(Environment.GetEnvironmentVariable).ToArray();
        int checks = 0;
        void Check(bool value) { checks++; if (!value) throw new Exception("Session binding check " + checks); }
        JsonObject game = new() { ["id"] = id, ["name"] = "Synthetic", ["version"] = 0L, ["contentIdentity"] = new string('b', 64) };
        JsonObject Request(string operation = "recover") => new() {
            ["game"] = game.DeepClone(), ["operation"] = operation, ["dataRoot"] = root, ["workRoot"] = work
        };
        void Reject(JsonObject request, string code) {
            var result = JsonNode.Parse(Execute(request.ToJsonString()));
            if (result["ok"].GetValue<bool>() || result["error"]["code"].GetValue<string>() != code)
                throw new Exception("Unexpected synthetic response: " + result.ToJsonString());
            Check(true);
        }
        try
        {
            Environment.SetEnvironmentVariable(keys[0], new JsonObject {
                ["schema"] = 1, ["id"] = "02", ["name"] = "Synthetic", ["accountUid"] = uid, ["stateRoot"] = root
            }.ToJsonString());
            Environment.SetEnvironmentVariable(keys[1], root);
            Environment.SetEnvironmentVariable(keys[2], id);
            var wrong = Request(); wrong["dataRoot"] = Path.Combine(temp, "other");
            Reject(wrong, "save_wrong_user"); Check(!Directory.Exists(work));
            wrong = Request(); wrong["game"]["id"] = "0100000000000002";
            Reject(wrong, "save_wrong_user"); Check(!Directory.Exists(work));
            wrong = Request(); wrong["workRoot"] = Path.Combine(temp, "other-work");
            Reject(wrong, "save_wrong_user"); Check(!Directory.Exists(work));
            Reject(Request("restore"), "save_changed"); Check(!Directory.Exists(work));
            wrong = Request("restore"); wrong["previewUserBinding"] = new string('0', 64);
            Reject(wrong, "save_changed"); Check(!Directory.Exists(work));
            var c = new Context(Request());
            Check(c.SelectedAccountUid == uid && c.SessionBinding.Length == 64);
            var restore = Request("restore"); restore["previewUserBinding"] = c.SessionBinding;
            Check(new Context(restore).SessionBinding == c.SessionBinding);
            // Empty target must not admit another user's archive ownership.
            JsonObject manifest = new() { ["game"] = game.DeepClone(), ["saveEntries"] = new JsonArray(
                new JsonObject { ["type"] = "account", ["userId"] = new string('c', 32) }) };
            bool rejected = false;
            try { Identity(c, manifest); } catch (Failure e) { rejected = e.Code == "save_wrong_user"; }
            Check(rejected && !Directory.Exists(root));
            manifest["saveEntries"][0]["userId"] = uid;
            Identity(c, manifest); Check(!Directory.Exists(root));
            Environment.SetEnvironmentVariable(keys[0], null);
            Environment.SetEnvironmentVariable(keys[1], null);
            Environment.SetEnvironmentVariable(keys[2], null);
            Check(new Context(Request()).SessionBinding == null);
            Console.WriteLine($"save session binding: {checks} checks passed (synthetic only)");
        }
        finally
        {
            for (int i = 0; i < keys.Length; i++) Environment.SetEnvironmentVariable(keys[i], old[i]);
            Directory.Delete(temp, true);
        }
    }
}
