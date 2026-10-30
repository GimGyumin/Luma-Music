import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from sync_copyright import START, END, apply, copyright_values, plan


class CopyrightSyncTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.db = Path(self.directory.name) / "navidrome.db"
        self.conn = sqlite3.connect(self.db)
        self.addCleanup(self.conn.close)
        self.conn.execute("CREATE TABLE media_file (id TEXT PRIMARY KEY, tags TEXT, comment TEXT, album TEXT, artist TEXT, updated_at TEXT)")

    def song(self, song_id="one", tags=None, comment=None, album="Dangerous"):
        self.conn.execute("INSERT INTO media_file VALUES (?, ?, ?, ?, ?, ?)", (
            song_id, json.dumps(tags if tags is not None else {"copyright": ["℗ 1991 MJJ Productions Inc."]}),
            comment, album, "Michael Jackson", "1991-11-26T08:00:00Z"
        ))
        self.conn.commit()

    def test_legacy_and_current_tag_formats_and_aliases(self):
        for tags in ({"copyright": [{"value": " ℗ 1991 MJJ "}]},
                     {"copyright": ["℗ 1991 MJJ"]}, {"CPRT": "℗ 1991 MJJ"}):
            with self.subTest(tags=tags):
                self.assertEqual(copyright_values(json.dumps(tags)), ["℗ 1991 MJJ"])

    def test_dry_run_does_not_write_or_create_backup(self):
        self.song()
        changes, counts = plan(self.conn)
        self.assertEqual(counts["needs_update"], 1)
        self.assertEqual(changes[0][0], f"{START}\n℗ 1991 MJJ Productions Inc.\n{END}")
        self.assertIsNone(self.conn.execute("SELECT comment FROM media_file").fetchone()[0])
        self.assertEqual(list(Path(self.directory.name).iterdir()), [self.db])

    def test_apply_preserves_description_tags_and_file_timestamp(self):
        self.song(comment="  Existing album notes.\n")
        before = self.conn.execute("SELECT tags, updated_at FROM media_file").fetchone()
        changes, _ = plan(self.conn)
        backup = apply(self.db, changes)
        credit = self.conn.execute("SELECT comment FROM media_file").fetchone()[0]
        self.assertTrue(credit.endswith("\n\n  Existing album notes.\n"))
        self.assertEqual(self.conn.execute("SELECT tags, updated_at FROM media_file").fetchone(), before)
        with sqlite3.connect(backup) as original:
            self.assertEqual(original.execute("SELECT comment FROM media_file").fetchone()[0], "  Existing album notes.\n")
        self.assertEqual(plan(self.conn)[1]["already_marked"], 1)

    def test_all_rights_lines_preserved_and_deduplicated(self):
        self.song(tags={"copyright": [{"value": "℗ First"}, {"value": "© Second"}, {"value": "℗ First"}]})
        changes, _ = plan(self.conn)
        self.assertEqual(changes[0][0], f"{START}\n℗ First\n© Second\n{END}")

    def test_malformed_and_empty_blocks_are_not_silently_overwritten(self):
        for i, comment in enumerate((START + "\nCredit", END, START + "\n" + END)):
            self.song(song_id=str(i), comment=comment)
        changes, counts = plan(self.conn)
        self.assertEqual(changes, [])
        self.assertEqual(counts["invalid_markers"], 3)

    def test_bad_or_missing_tags_are_reported(self):
        self.song("missing", tags={})
        self.song("invalid", tags={"copyright": [123]})
        self.song("broken")
        self.conn.execute("UPDATE media_file SET tags = ? WHERE id = ?", ("not json", "broken"))
        self.conn.commit()
        changes, counts = plan(self.conn)
        self.assertEqual(changes, [])
        self.assertEqual(counts["invalid_tags"], 2)
        self.assertEqual(counts["no_copyright"], 1)

    def test_filter_limits_album_and_artist(self):
        self.song("wanted")
        self.song("other", album="Other album")
        changes, counts = plan(self.conn, "Dangerous", "Michael Jackson")
        self.assertEqual(counts["scanned"], 1)
        self.assertEqual(changes[0][1], "wanted")

    def test_concurrent_change_rolls_back_every_edit(self):
        self.song("one")
        self.song("two")
        changes, _ = plan(self.conn)
        self.conn.execute("UPDATE media_file SET comment = 'New server data' WHERE id = 'two'")
        self.conn.commit()
        with self.assertRaises(RuntimeError):
            apply(self.db, changes)
        self.assertEqual(self.conn.execute("SELECT comment FROM media_file WHERE id = 'one'").fetchone(), (None,))
        self.assertEqual(self.conn.execute("SELECT comment FROM media_file WHERE id = 'two'").fetchone(), ("New server data",))

    def test_backup_includes_committed_wal_content(self):
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.song(comment="From WAL")
        changes, _ = plan(self.conn)
        backup = apply(self.db, changes)
        with sqlite3.connect(backup) as original:
            self.assertEqual(original.execute("SELECT comment FROM media_file").fetchone(), ("From WAL",))


if __name__ == "__main__":
    unittest.main()
