"""Probe a disposable Navidrome installation and optionally run the Luma tests against it.

python3 scripts/navidrome/test_replay_history.py /path/to/navidrome [test-command ...]
The child receives only a temporary listener login. No installed server or music is modified.
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import wave


def run(binary, command, web=False):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        music = root / "music"
        music.mkdir()
        with wave.open(str(music / "Replay.wav"), "wb") as song:
            song.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
            song.writeframes(bytes(44100 * 2))
        if web:
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=80:duration=65",
                            "-codec:a", "libmp3lame", "-b:a", "64k", str(music / "Replay.mp3")], check=True)
            (music / "Replay.wav").unlink()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        proc = subprocess.Popen([binary, "--datafolder", tmp, "--musicfolder", str(music)],
                                cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env={**os.environ, "ND_ADDRESS": "127.0.0.1", "ND_PORT": str(port),
                                     "ND_ENABLEINSIGHTSCOLLECTOR": "false", "ND_ENABLEEXTERNALSERVICES": "false"})

        def request(path, body=None, token=None):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["x-nd-authorization"] = "Bearer " + token
            req = Request(base + path, data=json.dumps(body).encode() if body else None, headers=headers)
            with urlopen(req, timeout=5) as response:
                return json.load(response)

        def status(path, token=None):
            try:
                request(path, token=token)
                return 200
            except HTTPError as error:
                return error.code

        try:
            for _ in range(120):
                try:
                    status("/api/scrobble")
                    break
                except URLError:
                    time.sleep(0.2)
            password = secrets.token_urlsafe(20)
            request("/auth/createAdmin", {"username": "setup", "password": password})
            admin = request("/auth/login", {"username": "setup", "password": password})["token"]
            tokens = {}
            for name in ["listener", "other"]:
                request("/api/user", {"userName": name, "name": name, "password": password, "isAdmin": False}, admin)
                tokens[name] = request("/auth/login", {"username": name, "password": password})["token"]
            native = status("/api/scrobble", tokens["listener"])
            if native == 404:
                print("Authenticated native scrobble route unavailable (404)", flush=True)
                return 0 if not command else 1
            assert native == 200 and status("/api/scrobble") == 401
            for _ in range(100):
                songs = request("/api/song?_start=0&_end=1", token=tokens["listener"])
                if songs:
                    break
                time.sleep(0.2)
            track = songs[0]["id"]
            now = int(time.time()) - 60
            for stamp, submit in [(now, False), (now, True), (now, True), (now - 10000, True)]:
                salt = secrets.token_hex(8)
                query = urlencode(dict(u="listener", s=salt, t=hashlib.md5((password+salt).encode()).hexdigest(),
                                       v="1.16.1", c="luma-replay-test", f="json", id=track, time=stamp*1000,
                                       submission=str(submit).lower()))
                assert request("/rest/scrobble?" + query)["subsonic-response"]["status"] == "ok"
            def page(start, end, name="listener"):
                return request(f"/api/scrobble?_start={start}&_end={end}&_sort=id&_order=ASC", token=tokens[name])
            rows = page(0, 2) + page(2, 4)
            assert len(rows) == 3 and len({r["id"] for r in rows}) == 3
            assert [r["submissionTime"] for r in rows] == [now, now, now-10000]
            assert len(request(f"/api/scrobble?from={now}&to={now}", token=tokens["listener"])) == 2
            assert page(0, 5, "other") == []
            print("Verified ordinary-user JWT, two pages, repeat plays, late report and account isolation", flush=True)
            fixture = dict(base=base, password=password, track=track, now=now, initialCount=3)
            if web:
                subprocess.run(["node", str(Path(__file__).with_name("replay_web_client.mjs"))],
                               env={**os.environ, "LUMA_REPLAY_FIXTURE": json.dumps(fixture)}, check=True, timeout=180)
                fixture["initialCount"] = 4
            if command:
                fixture = json.dumps(fixture)
                return subprocess.run(command, env={**os.environ, "TEST_RUNNER_LUMA_REPLAY_FIXTURE": fixture,
                                                    "LUMA_REPLAY_FIXTURE": fixture}).returncode
            return 0
        finally:
            proc.terminate()
            proc.wait(timeout=15)

if __name__ == "__main__":
    args = sys.argv[1:]
    web = args[0] == "--web"
    if web:
        args = args[1:]
    sys.exit(run(shutil.which(args[0]) or str(Path(args[0]).resolve()), args[1:], web=web))
