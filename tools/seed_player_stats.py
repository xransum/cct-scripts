#!/usr/bin/env python3
"""
seed_player_stats.py
====================
One-time tool: reads Minecraft server statistics files and writes an initial
player_stats.cfg for CC:Tweaked computer 17.

The generated file is compatible with textutils.unserialize in CC:Tweaked and
seeds each known player's:
  - totalMs   (from minecraft:play_time ticks × 50 ms/tick)
  - deaths    (from minecraft:deaths)
  - lastSeen  (epoch ms, set to now as a conservative default)

If player_stats.cfg already exists on the computer, the script merges by
taking the MAX totalMs so it never decreases an existing value.

Usage
-----
# Dump straight from the live server (reads via SSH):
  python3 tools/seed_player_stats.py

# Override SSH host or server root:
  python3 tools/seed_player_stats.py --ssh-host serverhub-mc \\
      --server-root /home/minecraft/atm10-71

# Write to a specific output file instead of stdout:
  python3 tools/seed_player_stats.py --out player_stats.cfg

# Then deploy:
  scp player_stats.cfg "serverhub-mc:/home/minecraft/atm10-71/world/computercraft/computer/17/"
"""

import argparse
import json
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Defaults matching the known server setup
# ---------------------------------------------------------------------------
DEFAULT_SSH_HOST    = "serverhub-mc"
DEFAULT_SERVER_ROOT = "/home/minecraft/atm10-71"

TICKS_PER_MS = 50   # 1 game tick = 50 ms  (20 ticks/s → 1000 ms/s)


# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------

def ssh_cat(host: str, remote_path: str) -> str:
    result = subprocess.run(
        ["ssh", host, f"cat {remote_path}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise FileNotFoundError(f"Cannot read {remote_path!r} from {host}: {result.stderr.strip()}")
    return result.stdout


def ssh_ls(host: str, remote_dir: str) -> list[str]:
    result = subprocess.run(
        ["ssh", host, f"ls {remote_dir}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return []
    return [f for f in result.stdout.strip().split("\n") if f]


# ---------------------------------------------------------------------------
# Lua table serializer (matches textutils.serialize output closely enough for
# textutils.unserialize to accept it)
# ---------------------------------------------------------------------------

def lua_str(s: str) -> str:
    escaped = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def lua_serialize(obj, _indent: int = 0) -> str:
    pad  = "  " * _indent
    ipad = "  " * (_indent + 1)
    if obj is None:
        return "nil"
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if isinstance(obj, int):
        return str(obj)
    if isinstance(obj, float):
        return repr(obj)
    if isinstance(obj, str):
        return lua_str(obj)
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        lines = ["{"]
        for k, v in obj.items():
            if v is None:
                continue  # nil in Lua means absent
            key = f"[{lua_str(k)}]" if isinstance(k, str) else f"[{k}]"
            lines.append(f"{ipad}{key} = {lua_serialize(v, _indent + 1)},")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    raise TypeError(f"Cannot serialize {type(obj).__name__}: {obj!r}")


# ---------------------------------------------------------------------------
# Parse Minecraft stats JSON (1.13+ format)
# ---------------------------------------------------------------------------

def parse_stats(raw_json: str) -> tuple[int, int]:
    """Return (play_time_ticks, deaths) from a player stats JSON."""
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError:
        return 0, 0
    custom = data.get("stats", {}).get("minecraft:custom", {})
    play_ticks = custom.get("minecraft:play_time", 0)
    deaths     = custom.get("minecraft:deaths",    0)
    return int(play_ticks), int(deaths)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ssh-host",    default=DEFAULT_SSH_HOST,
                    help=f"SSH host alias (default: {DEFAULT_SSH_HOST})")
    ap.add_argument("--server-root", default=DEFAULT_SERVER_ROOT,
                    help=f"Server installation root (default: {DEFAULT_SERVER_ROOT})")
    ap.add_argument("--out", default="-",
                    help="Output file path; use '-' for stdout (default: -)")
    args = ap.parse_args()

    host        = args.ssh_host
    root        = args.server_root.rstrip("/")
    usercache   = f"{root}/usercache.json"
    stats_dir   = f"{root}/world/stats"

    # ── load usercache (UUID → name) ─────────────────────────────────────────
    print(f"[seed] Reading usercache from {host}:{usercache} …", file=sys.stderr)
    try:
        cache_raw = ssh_cat(host, usercache)
        cache     = json.loads(cache_raw)
    except Exception as exc:
        print(f"[seed] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    uuid_to_name: dict[str, str] = {}
    for entry in cache:
        uuid = entry.get("uuid", "").lower().replace("-", "")
        name = entry.get("name", "")
        if uuid and name:
            uuid_to_name[uuid] = name

    print(f"[seed] Found {len(uuid_to_name)} player(s) in usercache.", file=sys.stderr)

    # ── enumerate stats files ─────────────────────────────────────────────────
    print(f"[seed] Listing {host}:{stats_dir} …", file=sys.stderr)
    stat_files = [f for f in ssh_ls(host, stats_dir) if f.endswith(".json")]
    print(f"[seed] Found {len(stat_files)} stats file(s).", file=sys.stderr)

    # ── build player records ──────────────────────────────────────────────────
    now_ms  = int(time.time() * 1000)
    players: dict[str, dict] = {}

    for fname in stat_files:
        uuid_raw = fname.replace(".json", "").lower().replace("-", "")
        name = uuid_to_name.get(uuid_raw)
        if not name:
            # UUID not in usercache; use filename as fallback key
            name = fname.replace(".json", "")
            print(f"[seed] WARNING: no usercache entry for {fname}; using raw UUID as name.",
                  file=sys.stderr)

        try:
            raw    = ssh_cat(host, f"{stats_dir}/{fname}")
            ticks, deaths = parse_stats(raw)
        except Exception as exc:
            print(f"[seed] WARNING: skipping {fname}: {exc}", file=sys.stderr)
            continue

        total_ms = ticks * TICKS_PER_MS
        players[name] = {
            "deaths":   deaths,
            "totalMs":  total_ms,
            "lastSeen": now_ms,
            # sessionStartMs absent → player treated as offline on first load
        }
        print(f"[seed]   {name:<24}  play={total_ms//3600000}h {(total_ms%3600000)//60000}m"
              f"  deaths={deaths}", file=sys.stderr)

    if not players:
        print("[seed] No player data found — nothing to write.", file=sys.stderr)
        sys.exit(0)

    # ── serialize ─────────────────────────────────────────────────────────────
    # _savedAt = 0 forces loadData() to treat this as a "server restart" state,
    # meaning no sessions are resumed (correct for an initial seed).
    out_table: dict = {"_savedAt": 0}
    out_table.update(players)

    lua_out = lua_serialize(out_table)

    if args.out == "-":
        print(lua_out)
    else:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(lua_out)
        print(f"[seed] Written to {args.out}", file=sys.stderr)
        print(f"[seed] Deploy with:", file=sys.stderr)
        print(f"[seed]   scp {args.out!r} "
              f'"serverhub-mc:/home/minecraft/atm10-71/world/computercraft/computer/17/"',
              file=sys.stderr)


if __name__ == "__main__":
    main()
