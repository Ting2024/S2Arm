"""本地玩家（#623）：Mac 启动器把顶栏选的玩家放进 launch 请求的 player 字段，作业层（build.runtime_env）给服务层
S2A_PLAYER_USER / S2A_PLAYER_NAME，存档位置换成这款文件夹里这个玩家的那个。期望手写（services/S2A.Services/LocalPlayer.cs 的约定）。"""
import os
import unittest
from unittest.mock import patch

from jobcase import JobCase
from core import Context, Failure
import build
import layout
import saves
import users

HONG = "d7a43a96495d0a594e615dd88587b6bf"
MING = "8f14e45fceea167a5a36dedd4bea2543"


class LocalPlayerEnvTests(JobCase):
    def game(self):
        return dict(id="0100000000000000", name="Test title", display="1.0", hidden=False, packages=[])

    def env(self, player):
        if player is None:
            self.c.r.pop("player", None)
        else:
            self.c.r["player"] = player
        with patch.dict(os.environ):
            os.environ.pop("S2A_PLAYER_USER", None)
            return build.runtime_env(self.c, self.game(), self.root / "runtime")

    def test_no_player_keeps_the_old_launch(self):
        env = self.env(None)
        self.assertNotIn("S2A_PLAYER_USER", env)
        self.assertNotIn("S2A_PLAYER_NAME", env)
        self.assertEqual(env["S2A_SAVE_FOLDER"], str(layout.path(self.c, self.game()["id"], "SaveData")))
        self.assertFalse((self.c.library / "saves" / self.game()["id"]).exists())

    def test_first_player_keeps_savedata_and_second_gets_her_own_folder(self):
        gid = self.game()["id"]
        env_first = self.env(dict(user="first", name="", folder="SaveData"))
        self.assertEqual((env_first["S2A_PLAYER_USER"], env_first.get("S2A_PLAYER_NAME")), ("first", None))
        self.assertEqual(env_first["S2A_SAVE_FOLDER"], str(layout.path(self.c, gid, "SaveData")))
        self.assertEqual(env_first["S2A_MNG_INPUT_ROOT"], str((self.c.library / "mappings" / "mng" / gid).resolve()))
        (self.c.library / "mappings" / "mng" / gid / "controls.txt").write_text("jump=space\n", encoding="utf-8")
        env = self.env(dict(user=HONG, name="Hong", folder="SaveData-Hong"))
        self.assertEqual((env["S2A_PLAYER_USER"], env["S2A_PLAYER_NAME"]), (HONG, "Hong"))
        self.assertEqual(env["S2A_SAVE_FOLDER"], str(layout.path(self.c, gid, "SaveData-Hong")))
        # 不同本地玩家的输入目录与临时文档目录彼此独立，避免同时运行同一款游戏时争抢 .input-owner.lock
        self.assertEqual(env["S2A_MNG_INPUT_ROOT"], str((self.c.library / "mappings" / "players" / HONG / "mng" / gid).resolve()))
        self.assertEqual((self.c.library / "mappings" / "players" / HONG / "mng" / gid / "controls.txt").read_text(encoding="utf-8"), "jump=space\n")
        self.assertNotEqual(env["S2A_DOCS"], env_first["S2A_DOCS"])
        # Ryujinx 数据根不按玩家分（存档按用户号隔离在同一个数据根里）
        self.assertEqual(env["S2A_RYU_DATA"], str(layout.path(self.c, gid, "saves")))
        self.assertFalse((self.c.library / "saves" / gid).exists())

    def test_empty_legacy_saves_dir_does_not_shadow_game_folder_saves(self):
        gid = self.game()["id"]
        (self.c.library / "saves" / gid).mkdir(parents=True, exist_ok=True)
        root, _, _ = saves.locations(self.c, self.game())
        self.assertEqual(root, layout.path(self.c, gid, "saves", create=False))

    def test_different_local_players_have_independent_session_locks(self):
        gid = self.game()["id"]
        c_first = Context(dict(self.c.r, taskId="task-first", player=dict(user="first", name="", folder="SaveData")))
        c_hong = Context(dict(self.c.r, taskId="task-hong", player=dict(user=HONG, name="Hong", folder="SaveData-Hong")))
        c_hong_dup = Context(dict(self.c.r, taskId="task-hong-2", player=dict(user=HONG, name="Hong", folder="SaveData-Hong")))
        c_ming = Context(dict(self.c.r, taskId="task-ming", player=dict(user=MING, name="Ming", folder="SaveData-Ming")))
        with users.session_lock(c_first, gid):
            with users.session_lock(c_hong, gid):
                with users.session_lock(c_ming, gid):
                    with self.assertRaises(Failure):
                        with users.session_lock(c_hong_dup, gid):
                            pass

    def test_bad_players_are_rejected(self):
        for bad in ("first", dict(user="first", name="", folder="SaveData-x"), dict(user=HONG, name="H", folder="SaveData"),
                    dict(user="0" * 32, name="", folder="SaveData-a"), dict(user=HONG.upper(), name="", folder="SaveData-a"),
                    dict(user=HONG, name="", folder="SaveData-../../x"), dict(user=HONG, name="", folder="../SaveData"),
                    dict(user=HONG, name=3, folder="SaveData-a")):
            with self.subTest(bad=bad), self.assertRaises(Failure):
                self.env(bad)


if __name__ == "__main__":
    unittest.main()
