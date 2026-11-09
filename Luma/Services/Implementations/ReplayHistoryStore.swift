import Foundation
import SQLite3
import SwiftSonic
import CryptoKit

/// A separate local mirror. Installing, rebuilding or disabling it never modifies the listening store.
nonisolated final class ReplayHistoryStore {
    enum Failure: Error { case database, invalidPage }
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Failure.database
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS events(uid TEXT NOT NULL,id INTEGER NOT NULL,track TEXT NOT NULL,stamp INTEGER NOT NULL,
                PRIMARY KEY(uid,id));
            CREATE INDEX IF NOT EXISTS replay_match ON events(uid,track,stamp);
            CREATE INDEX IF NOT EXISTS replay_period ON events(uid,stamp);
            CREATE TABLE IF NOT EXISTS checkpoint(uid TEXT PRIMARY KEY,n INTEGER NOT NULL,last INTEGER NOT NULL,completed REAL);
            CREATE TABLE IF NOT EXISTS submissions(session TEXT PRIMARY KEY,track TEXT NOT NULL,stamp INTEGER NOT NULL,owner TEXT NOT NULL,state INTEGER NOT NULL DEFAULT 0,attemptedAt REAL);
            CREATE INDEX IF NOT EXISTS replay_submission ON submissions(owner,state,stamp,track);
            """)
    }
    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database }
    }
    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw Failure.database }
        defer { sqlite3_finalize(s) }
        return try body(s)
    }
    private func bind(_ s: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(s,index,value,-1,transient) == SQLITE_OK else { throw Failure.database }
    }
    private func done(_ s: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw Failure.database }
    }

    func cursor(_ uid: String) throws -> (count: Int, last: Int64, completed: Date?) {
        try statement("SELECT n,last,completed FROM checkpoint WHERE uid=?") { s in
            try bind(s,1,uid)
            switch sqlite3_step(s) {
            case SQLITE_DONE: return (0,0,nil)
            case SQLITE_ROW: return (Int(sqlite3_column_int64(s,0)),sqlite3_column_int64(s,1),
                sqlite3_column_type(s,2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s,2)))
            default: throw Failure.database
            }
        }
    }

    func save(_ page: [NavidromeScrobble], uid: String, offset: Int, previous: Int64, complete: Bool) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            var last = previous
            try statement("INSERT INTO events VALUES(?,?,?,?) ON CONFLICT(uid,id) DO UPDATE SET track=excluded.track,stamp=excluded.stamp") { s in
                for row in page {
                    try Task.checkCancellation()
                    guard row.id > last, !row.mediaFileId.isEmpty, row.submissionTime > 0 else { throw Failure.invalidPage }
                    last = row.id
                    sqlite3_reset(s)
                    try bind(s,1,uid); sqlite3_bind_int64(s,2,row.id); try bind(s,3,row.mediaFileId)
                    sqlite3_bind_int64(s,4,row.submissionTime); try done(s)
                }
            }
            try statement("""
                INSERT INTO checkpoint VALUES(?,?,?,?) ON CONFLICT(uid) DO UPDATE SET
                n=excluded.n,last=excluded.last,completed=COALESCE(excluded.completed,checkpoint.completed)
                """) { s in
                try bind(s,1,uid); sqlite3_bind_int64(s,2,Int64(offset + page.count)); sqlite3_bind_int64(s,3,last)
                if complete { sqlite3_bind_double(s,4,Date().timeIntervalSince1970) }
                try done(s)
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    func reset(_ uid: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for sql in ["DELETE FROM events WHERE uid=?", "DELETE FROM checkpoint WHERE uid=?"] {
                try statement(sql) { s in try bind(s, 1, uid); try done(s) }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    /// Atomically publish a full reconciliation. Readers continue using the previous complete history during a scan.
    func publish(scan: String, uid: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for table in ["events", "checkpoint"] {
                try statement("DELETE FROM " + table + " WHERE uid=?") { s in try bind(s,1,uid); try done(s) }
                try statement("UPDATE " + table + " SET uid=? WHERE uid=?") { s in try bind(s,1,uid); try bind(s,2,scan); try done(s) }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    func reconcileSubmissions(uid: String, owner: String) throws {
        // A server row with an ambiguous acknowledgement stays unlinked. Retain the local
        // session either way. Wait a minute before retrying a request absent from a complete mirror.
        try statement("""
            UPDATE submissions SET state=CASE WHEN EXISTS
                (SELECT 1 FROM events e WHERE e.uid=? AND e.track=submissions.track AND e.stamp=submissions.stamp)
                THEN 3 ELSE 0 END WHERE owner=? AND state=1 AND attemptedAt < ?
            """) { s in
            try bind(s,1,uid); try bind(s,2,owner); sqlite3_bind_double(s,3,Date().timeIntervalSince1970 - 60); try done(s)
        }
    }

    func firstDate(uid: String) throws -> Date? {
        try statement("SELECT stamp FROM events WHERE uid=? ORDER BY stamp LIMIT 1") { s in
            try bind(s,1,uid)
            guard sqlite3_step(s) == SQLITE_ROW else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(s,0))
        }
    }

    func hasEvents(uid: String, start: Date, end: Date) throws -> Bool {
        try statement("SELECT 1 FROM events WHERE uid=? AND stamp>=? AND stamp<? LIMIT 1") { s in
            try bind(s,1,uid); sqlite3_bind_double(s,2,start.timeIntervalSince1970); sqlite3_bind_double(s,3,end.timeIntervalSince1970)
            return sqlite3_step(s) == SQLITE_ROW
        }
    }

    /// Receipts prove a submission was acknowledged. Link only a one-to-one exact match.
    func linkedSessions(uid: String, owner: String, start: Date, end: Date) throws -> Set<UUID> {
        try statement("""
            SELECT min(s.session) FROM submissions s JOIN events e ON e.uid=? AND e.track=s.track AND e.stamp=s.stamp
            WHERE s.owner=? AND s.state=2 AND s.stamp>=? AND s.stamp<? GROUP BY s.track,s.stamp HAVING count(*)=1
            """) { s in
            try bind(s,1,uid); try bind(s,2,owner)
            sqlite3_bind_double(s,3,start.timeIntervalSince1970); sqlite3_bind_double(s,4,end.timeIntervalSince1970)
            var sessions = Set<UUID>()
            while sqlite3_step(s) == SQLITE_ROW {
                if let id = UUID(uuidString: String(cString: sqlite3_column_text(s,0))) { sessions.insert(id) }
            }
            return sessions
        }
    }

    func enumerate(uid: String, start: Date, end: Date, _ body: (Int64,String,Int64) -> Void) throws {
        try statement("SELECT id,track,stamp FROM events WHERE uid=? AND stamp>=? AND stamp<? ORDER BY stamp,id") { s in
            try bind(s,1,uid); sqlite3_bind_double(s,2,start.timeIntervalSince1970); sqlite3_bind_double(s,3,end.timeIntervalSince1970)
            while true {
                switch sqlite3_step(s) {
                case SQLITE_DONE: return
                case SQLITE_ROW:
                    try Task.checkCancellation()
                    body(sqlite3_column_int64(s,0), String(cString: sqlite3_column_text(s,1)), sqlite3_column_int64(s,2))
                default: throw Failure.database
                }
            }
        }
    }

    func enqueue(session: UUID, track: String, date: Date, owner: String) throws {
        try statement("INSERT OR IGNORE INTO submissions(session,track,stamp,owner) VALUES(?,?,?,?)") { s in
            try bind(s,1,session.uuidString); try bind(s,2,track); sqlite3_bind_int64(s,3,Int64(date.timeIntervalSince1970)); try bind(s,4,owner); try done(s)
        }
    }
    struct Submission { let session: String; let track: String; let stamp: Int64 }
    func pending(owner: String) throws -> [Submission] {
        try statement("SELECT session,track,stamp FROM submissions WHERE owner=? AND state=0 ORDER BY stamp,session LIMIT 100") { s in
            try bind(s,1,owner)
            var rows: [Submission] = []
            while true {
                switch sqlite3_step(s) {
                case SQLITE_DONE: return rows
                case SQLITE_ROW: rows.append(.init(session:String(cString:sqlite3_column_text(s,0)),track:String(cString:sqlite3_column_text(s,1)),stamp:sqlite3_column_int64(s,2)))
                default: throw Failure.database
                }
            }
        }
    }
    func mark(_ session: String, state: Int32) throws {
        try statement("UPDATE submissions SET state=?,attemptedAt=unixepoch() WHERE session=?") { s in
            sqlite3_bind_int(s,1,state); try bind(s,2,session); try done(s)
        }
    }
}

extension ServerSnapshot {
    /// The profile UUID survives relaunch. A changed destination or login must authenticate before it can see another mirror.
    nonisolated var replayProfile: String {
        let digest = SHA256.hash(data: Data((baseURL + "\u{0}" + username).utf8))
        return id.uuidString + "-" + digest.map { String(format:"%02x",$0) }.joined()
    }
}
