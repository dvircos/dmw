"""One-shot setup: database schema, GitHub repo, Actions secrets, and Pages.

Reads credentials from the environment. Nothing secret is written into the repo.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib
from base64 import b64encode
from pathlib import Path

import psycopg2
import requests
from nacl import encoding, public

ROOT = Path(__file__).resolve().parent
REPO_NAME = "dmw"
GITHUB_API = "https://api.github.com"
SECRETS = ("GITHUB_TOKEN", "SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_DB_PASSWORD", "API_KEY")


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing environment variable {name}")
    return value


def sanitize(text: str) -> str:
    cleaned = text or ""
    for name in SECRETS:
        value = os.environ.get(name, "")
        if value:
            cleaned = cleaned.replace(value, "***")
    return cleaned


def split_sql(sql: str) -> list[str]:
    statements: list[str] = []
    buf: list[str] = []
    i = 0
    n = len(sql)
    while i < n:
        ch = sql[i]
        if ch == "-" and i + 1 < n and sql[i + 1] == "-":
            while i < n and sql[i] != "\n":
                buf.append(sql[i])
                i += 1
            continue
        if ch == "/" and i + 1 < n and sql[i + 1] == "*":
            end = sql.find("*/", i + 2)
            if end < 0:
                raise RuntimeError("unterminated block comment")
            buf.append(sql[i : end + 2])
            i = end + 2
            continue
        if ch == "'":
            buf.append(ch)
            i += 1
            while i < n:
                buf.append(sql[i])
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        buf.append(sql[i + 1])
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if ch == "$":
            match = re.match(r"\$[A-Za-z0-9_]*\$", sql[i:])
            if match:
                tag = match.group(0)
                end = sql.find(tag, i + len(tag))
                if end < 0:
                    raise RuntimeError("unterminated dollar quote")
                buf.append(sql[i : end + len(tag)])
                i = end + len(tag)
                continue
        if ch == ";":
            statement = "".join(buf).strip()
            if meaningful(statement):
                statements.append(statement)
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if meaningful(tail):
        statements.append(tail)
    return statements


def meaningful(statement: str) -> bool:
    without_block = re.sub(r"/\*.*?\*/", "", statement, flags=re.S)
    without_line = re.sub(r"--.*?$", "", without_block, flags=re.M)
    return bool(without_line.strip())


def write_png(path: Path, size: int) -> None:
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            raw.extend(pixel(x, y, size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def pixel(x: int, y: int, size: int) -> tuple[int, int, int, int]:
    nx = (x + 0.5) / size
    ny = (y + 0.5) / size
    dx = nx - 0.5
    dy = ny - 0.5
    radius = (dx * dx + dy * dy) ** 0.5
    if radius > 0.5:
        return (0, 0, 0, 0)
    color = (8, 22, 40, 255)
    if radius > 0.42:
        color = (231, 182, 90, 255)
    if ((nx - 0.5) / 0.18) ** 2 + ((ny - 0.38) / 0.15) ** 2 <= 1:
        color = (231, 182, 90, 255)
    if 0.46 < nx < 0.54 and 0.50 < ny < 0.68:
        color = (231, 182, 90, 255)
    if 0.34 < nx < 0.66 and 0.66 < ny < 0.74:
        color = (231, 182, 90, 255)
    return color


def create_icons() -> None:
    folder = ROOT / "icons"
    folder.mkdir(exist_ok=True)
    for size in (192, 512):
        write_png(folder / f"icon-{size}.png", size)


def github_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def connect_database(project_ref: str, password: str):
    regions = [
        "eu-central-1",
        "eu-central-2",
        "eu-west-1",
        "eu-west-2",
        "eu-west-3",
        "eu-north-1",
        "us-east-1",
        "us-east-2",
        "us-west-1",
        "us-west-2",
        "ap-southeast-1",
        "ap-southeast-2",
        "ap-northeast-1",
        "ap-south-1",
        "sa-east-1",
        "ca-central-1",
    ]
    attempts = [(f"db.{project_ref}.supabase.co", "postgres")]
    for prefix in ("aws-0", "aws-1"):
        for region in regions:
            attempts.append((f"{prefix}-{region}.pooler.supabase.com", f"postgres.{project_ref}"))
    last_error = "no attempt"
    for host, user in attempts:
        try:
            conn = psycopg2.connect(
                host=host,
                port=5432,
                dbname="postgres",
                user=user,
                password=password,
                sslmode="require",
                connect_timeout=8,
            )
            print(f"Connected to database host {host}")
            return conn
        except Exception as exc:
            last_error = f"{host}: {exc.__class__.__name__}: {sanitize(str(exc))[:220]}"
            print(f"Skipped database host {host} ({exc.__class__.__name__})")
    raise RuntimeError(last_error)


def apply_schema(database_url: str, password: str) -> None:
    project_ref = database_url.split("//", 1)[1].split(".", 1)[0]
    sql = (ROOT / "schema.sql").read_text(encoding="utf-8")
    statements = split_sql(sql)
    print(f"Applying {len(statements)} SQL statements")
    conn = connect_database(project_ref, password)
    try:
        with conn:
            with conn.cursor() as cur:
                for index, statement in enumerate(statements, start=1):
                    try:
                        cur.execute(statement)
                    except Exception as exc:
                        preview = " ".join(statement.split())[:160]
                        raise RuntimeError(f"SQL statement {index} failed: {sanitize(str(exc))} :: {preview}") from exc
                cur.execute("select count(*) from public.games")
                game_count = cur.fetchone()[0]
                cur.execute(
                    """
                    select proname from pg_proc p
                    join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public'
                      and proname in ('place_bet', 'sync_game_result', 'ensure_profile')
                    order by proname
                    """
                )
                functions = [row[0] for row in cur.fetchall()]
        print(f"Schema ready. Games: {game_count}. Functions: {', '.join(functions)}")
    finally:
        conn.close()


def smoke_auth(url: str, anon_key: str, service_key: str) -> None:
    try:
        settings = requests.get(f"{url.rstrip('/')}/auth/v1/settings", headers={"apikey": anon_key}, timeout=30)
        print(f"Auth settings HTTP {settings.status_code}")
        email = f"mw-check-{uuid.uuid4().hex[:10]}@example.com"
        password = uuid.uuid4().hex + "Aa1"
        signup = requests.post(
            f"{url.rstrip('/')}/auth/v1/signup",
            headers={"apikey": anon_key, "Authorization": f"Bearer {anon_key}", "Content-Type": "application/json"},
            json={"email": email, "password": password, "data": {"username": "בודק"}},
            timeout=30,
        )
        body = signup.json() if signup.headers.get("content-type", "").startswith("application/json") else {}
        user_id = (body.get("user") or body).get("id") if isinstance(body, dict) else None
        session = body.get("access_token") or (body.get("session") or {}).get("access_token")
        if not session and user_id:
            signin = requests.post(
                f"{url.rstrip('/')}/auth/v1/token?grant_type=password",
                headers={"apikey": anon_key, "Content-Type": "application/json"},
                json={"email": email, "password": password},
                timeout=30,
            )
            session = signin.status_code == 200
        if user_id:
            requests.delete(
                f"{url.rstrip('/')}/auth/v1/admin/users/{user_id}",
                headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
                timeout=30,
            )
        if session:
            print("Auth smoke test passed and the temporary user was removed.")
        else:
            print("Auth smoke test did not get a session. In Supabase, turn off Confirm email under Authentication if signup stops at the inbox.")
    except Exception as exc:
        print("Auth smoke test skipped:", sanitize(str(exc))[:240])


def encrypt_secret(public_key: str, value: str) -> str:
    key = public.PublicKey(public_key.encode("utf-8"), encoding.Base64Encoder())
    sealed = public.SealedBox(key).encrypt(value.encode("utf-8"))
    return b64encode(sealed).decode("utf-8")


def put_secret(token: str, owner: str, name: str, value: str, key_id: str, key: str) -> None:
    response = requests.put(
        f"{GITHUB_API}/repos/{owner}/{REPO_NAME}/actions/secrets/{name}",
        headers=github_headers(token),
        json={"encrypted_value": encrypt_secret(key, value), "key_id": key_id},
        timeout=30,
    )
    if response.status_code not in (201, 204):
        raise RuntimeError(f"Failed to set secret {name}: HTTP {response.status_code} {sanitize(response.text)[:200]}")
    print(f"Set Actions secret {name}")


def find_git() -> str:
    found = shutil.which("git")
    if found:
        return found
    candidate = Path(r"C:\Program Files\Git\cmd\git.exe")
    if candidate.exists():
        return str(candidate)
    raise RuntimeError("git executable was not found")


def run_git(git: str, args: list[str], token: str | None = None) -> str:
    env = os.environ.copy()
    command = [git, *args]
    if token:
        command = [git, "-c", f"http.extraheader=AUTHORIZATION: bearer {token}", *args]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, env=env)
    output = sanitize((result.stderr or "") + (result.stdout or ""))
    if result.returncode != 0:
        raise RuntimeError(output.strip() or f"git {' '.join(args)} failed")
    return output


def publish(token: str, owner: str, email: str) -> None:
    headers = github_headers(token)
    created = requests.post(
        f"{GITHUB_API}/user/repos",
        headers=headers,
        json={
            "name": REPO_NAME,
            "description": "Mordechai Winners - virtual Nations League picks",
            "private": False,
            "auto_init": False,
            "has_issues": False,
        },
        timeout=30,
    )
    if created.status_code not in (201, 422):
        raise RuntimeError(f"Could not create the repository: HTTP {created.status_code} {sanitize(created.text)[:240]}")
    print("GitHub repository is ready." if created.status_code == 201 else "GitHub repository already exists.")

    key_response = requests.get(f"{GITHUB_API}/repos/{owner}/{REPO_NAME}/actions/secrets/public-key", headers=headers, timeout=30)
    key_response.raise_for_status()
    key_body = key_response.json()
    for name in ("SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_DB_PASSWORD", "API_KEY"):
        put_secret(token, owner, name, required(name), key_body["key_id"], key_body["key"])

    git = find_git()
    run_git(git, ["init", "-b", "main"])
    run_git(git, ["add", "-A"])
    status = subprocess.run([git, "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True)
    if status.stdout.strip():
        run_git(git, ["-c", f"user.name={owner}", "-c", f"user.email={email}", "commit", "-m", "Launch the virtual Nations League betting app."])
    else:
        print("Working tree already committed.")
    remotes = subprocess.run([git, "remote"], cwd=ROOT, capture_output=True, text=True)
    remote_url = f"https://github.com/{owner}/{REPO_NAME}.git"
    if "origin" in remotes.stdout.split():
        run_git(git, ["remote", "set-url", "origin", remote_url])
    else:
        run_git(git, ["remote", "add", "origin", remote_url])
    run_git(git, ["push", "-u", "origin", "main"], token=token)
    print("Pushed main.")

    pages_url = f"https://{owner}.github.io/{REPO_NAME}/"
    for _ in range(5):
        response = requests.post(
            f"{GITHUB_API}/repos/{owner}/{REPO_NAME}/pages",
            headers=headers,
            json={"build_type": "legacy", "source": {"branch": "main", "path": "/"}},
            timeout=30,
        )
        if response.status_code in (201, 409):
            print(f"GitHub Pages configured: {pages_url}")
            return
        time.sleep(3)
    raise RuntimeError(f"Pages was not enabled: HTTP {response.status_code} {sanitize(response.text)[:240]}")


def main() -> int:
    create_icons()
    url = required("SUPABASE_URL")
    try:
        apply_schema(url, required("SUPABASE_DB_PASSWORD"))
        smoke_auth(url, required("SUPABASE_ANON_KEY"), required("SUPABASE_SERVICE_ROLE_KEY"))
    except Exception as exc:
        print("SCHEMA_FAILED")
        print(sanitize(str(exc))[:800])

    token = required("GITHUB_TOKEN")
    user_response = requests.get(f"{GITHUB_API}/user", headers=github_headers(token), timeout=30)
    if user_response.status_code != 200:
        print(f"GITHUB_FAILED HTTP {user_response.status_code}")
        return 1
    user = user_response.json()
    owner = user["login"]
    email = user.get("email") or f"{user['id']}+{owner}@users.noreply.github.com"
    readme = ROOT / "README.md"
    readme.write_text(readme.read_text(encoding="utf-8").replace("PAGES_OWNER", owner), encoding="utf-8")
    try:
        publish(token, owner, email)
    except Exception as exc:
        print("GITHUB_FAILED")
        print(sanitize(str(exc))[:800])
        return 1
    print(f"LIVE_URL=https://{owner}.github.io/{REPO_NAME}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
