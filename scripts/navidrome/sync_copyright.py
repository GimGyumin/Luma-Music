#!/usr/bin/env python3
"""Inspect/repair copyright comments. Read-only unless --apply is supplied.

Run against a stopped Navidrome instance. Only the comment column is changed;
updated_at is a file timestamp in Navidrome, not a metadata edit timestamp.
"""

import argparse
import json
import os
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

START = "[[COPYRIGHT]]"
END = "[[/COPYRIGHT]]"


def copyright_values(raw_tags):
    """Accept both legacy [{value: ...}] and current [string] tag values."""
    tags = json.loads(raw_tags or "{}")
    if not isinstance(tags, dict):
        raise ValueError("tags must be a JSON object")
    normalized = {key.lower(): value for key, value in tags.items()}
    for name in ("copyright", "cprt", "tcop", "©cpy"):
        values = normalized.get(name, [])
        if isinstance(values, str):
            values = [values]
        if not isinstance(values, list):
            raise ValueError(f"unexpected {name} tag format")
        result = []
        for item in values:
            value = item.get("value") if isinstance(item, dict) else item
            if not isinstance(value, str):
                raise ValueError(f"unexpected {name} tag value")
            value = value.strip()
            if value and value not in result:
                result.append(value)
        if result:
            return result
    return []


def plan(conn, album=None, artist=None):
    columns = {row[1] for row in conn.execute("PRAGMA table_info(media_file)")}
    if not {"id", "tags", "comment"}.issubset(columns):
        raise ValueError("media_file is missing id/tags/comment; unsupported schema")
    predicates, params = [], []
    for column, value in (("album", album), ("artist", artist)):
        if value is not None:
            if column not in columns:
                raise ValueError(f"media_file is missing {column}")
            predicates.append(f"{column} = ?")
            params.append(value)
    query = "SELECT id, tags, comment FROM media_file"
    if predicates:
        query += " WHERE " + " AND ".join(predicates)
    changes, counts = [], Counter()
    for song_id, raw_tags, old_comment in conn.execute(query, params):
        counts["scanned"] += 1
        try:
            values = copyright_values(raw_tags)
        except (ValueError, TypeError):
            counts["invalid_tags"] += 1
            continue
        if not values:
            counts["no_copyright"] += 1
            continue
        counts["with_copyright"] += 1
        comment = old_comment or ""
        if START in comment or END in comment:
            start, end = comment.find(START), comment.find(END)
            if start >= 0 and end >= start + len(START) and comment[start + len(START):end].strip():
                counts["already_marked"] += 1
            else:
                counts["invalid_markers"] += 1
            continue
        block = START + "\n" + "\n".join(values) + "\n" + END
        new_comment = block + ("\n\n" + comment if comment.strip() else "")
        changes.append((new_comment, song_id, old_comment, raw_tags))
    counts["needs_update"] = len(changes)
    return changes, counts


def apply(db, changes):
    """Back up via SQLite (including WAL), then atomically apply the inspected plan."""
    if not changes:
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup = db.with_name(db.name + ".copyright-" + stamp + ".backup")
    # Never overwrite an existing backup, and keep its music metadata private.
    fd = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    conn = sqlite3.connect(db.as_uri() + "?mode=rw", uri=True, timeout=5)
    try:
        target = sqlite3.connect(backup)
        try:
            conn.backup(target)
        finally:
            target.close()
        conn.execute("BEGIN IMMEDIATE")
        for change in changes:
            cursor = conn.execute(
                "UPDATE media_file SET comment = ? WHERE id = ? AND comment IS ? AND tags IS ?",
                change,
            )
            if cursor.rowcount != 1:
                raise RuntimeError("DB changed since inspection; all comment edits rolled back")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--album", help="Exact album-name filter")
    parser.add_argument("--artist", help="Exact track-artist filter")
    parser.add_argument("--apply", action="store_true", help="Back up and write comments; stop Navidrome first")
    args = parser.parse_args()
    db = args.db.expanduser().resolve()
    if not db.is_file():
        parser.error(f"DB not found: {db}")
    try:
        conn = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=5)
        try:
            changes, counts = plan(conn, args.album, args.artist)
        finally:
            conn.close()
        print("MODE:", "APPLY" if args.apply else "READ-ONLY (no changes)")
        print("DB:", db)
        for key in ("scanned", "with_copyright", "needs_update", "already_marked", "no_copyright", "invalid_tags", "invalid_markers"):
            print(f"{key}: {counts[key]}")
        if args.apply:
            backup = apply(db, changes)
            print("Backup:", backup if backup else "No writes needed")
            print("Updated:", len(changes))
        else:
            print("Stop Navidrome before re-running with --apply. A rescan may overwrite DB-only comments.")
    except (sqlite3.Error, ValueError, OSError, RuntimeError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
