"""Fault drill: break the watched app on purpose, wait for the alert, read the incident note.

1. Sets FAULT_MODE on the Policy Assistant (a new Container Apps revision). Only /api/selftest
   is affected; signed-in users are not.
2. Calls /api/selftest every few seconds so the logs have something to measure.
3. Waits for Azure Monitor to fire the alert and the Logic App to run (this sends the real email).
4. Prints the incident note, then ALWAYS sets FAULT_MODE back to "off", even if something fails.

  python tests/fault_drill.py --mode errors --app-url https://... \
      --app-rg rg-policy-assistant-demo --app-name ca-policy-assistant \
      --workflow-id /subscriptions/.../workflows/la-incident-assistant

Needs an Azure sign-in that can update the Container App and read the Logic App's runs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
from send_sample_alert import az_rest  # noqa: E402  (management API with a CLI token)

API = "api-version=2019-05-01"


def az(*args: str) -> str:
    exe = shutil.which("az") or "az"
    return subprocess.run([exe, *args], capture_output=True, text=True, check=True).stdout


def set_mode(rg: str, app: str, mode: str) -> None:
    print(f"{now()} FAULT_MODE={mode} (new revision)")
    az("containerapp", "update", "-g", rg, "-n", app, "--set-env-vars", f"FAULT_MODE={mode}", "-o", "none")


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%H:%M:%S")


def hit(url: str) -> tuple[int, float]:
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(f"{url}/api/selftest", timeout=30) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        code = 0
    return code, time.perf_counter() - t


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--mode", required=True, choices=["errors", "slow", "ai"])
    p.add_argument("--app-url", required=True)
    p.add_argument("--app-rg", required=True)
    p.add_argument("--app-name", required=True)
    p.add_argument("--workflow-id", required=True)
    p.add_argument("--traffic-minutes", type=float, default=7)
    p.add_argument("--wait-minutes", type=float, default=15, help="how long to wait for the alert after traffic starts")
    a = p.parse_args()

    base = f"https://management.azure.com{a.workflow_id}"
    started = dt.datetime.now(dt.timezone.utc)
    set_mode(a.app_rg, a.app_name, a.mode)
    try:
        # Wait for the new revision to answer with the fault before counting.
        deadline = time.time() + 180
        while time.time() < deadline:
            code, _ = hit(a.app_url)
            if (a.mode in ("errors", "ai") and code == 500) or (a.mode == "slow" and code == 200):
                break
            time.sleep(5)
        print(f"{now()} fault is live; sending self-test traffic for {a.traffic_minutes:g} minutes")

        stats: dict[int, int] = {}
        slowest = 0.0
        stop_traffic = time.time() + a.traffic_minutes * 60
        give_up = time.time() + a.wait_minutes * 60
        run = None
        while time.time() < give_up:
            if time.time() < stop_traffic:
                code, secs = hit(a.app_url)
                stats[code] = stats.get(code, 0) + 1
                slowest = max(slowest, secs)
            runs = az_rest("GET", f"{base}/runs?{API}&$top=5")["value"]
            new = [r for r in runs
                   if dt.datetime.fromisoformat(r["properties"]["startTime"][:19] + "+00:00") > started
                   and r["properties"]["status"] not in ("Running", "Waiting")]
            if new:
                run = new[-1]
                break
            time.sleep(10)
        print(f"{now()} self-test responses: {stats}, slowest {slowest:.1f}s")

        if not run:
            print("FAILED: no alert reached the Logic App in time")
            return 1
        print(f"{now()} Logic App run {run['name']}: {run['properties']['status']} (started {run['properties']['startTime'][11:19]} UTC)")
        trig = az_rest("GET", f"{base}/runs/{run['name']}/actions/Alert?{API}")
        with urllib.request.urlopen(trig["properties"]["outputsLink"]["uri"]) as r:
            alert = json.loads(r.read())
        alert = alert.get("body", alert)
        print(f"alert: {alert.get('rule')} ({alert.get('severity')}, {alert.get('condition')})")
        note_action = az_rest("GET", f"{base}/runs/{run['name']}/actions/Incident_note?{API}")
        with urllib.request.urlopen(note_action["properties"]["outputsLink"]["uri"]) as r:
            note = json.loads(r.read())
        print(json.dumps(note.get("body", note) if "title" not in note else note, indent=2))
        send = az_rest("GET", f"{base}/runs/{run['name']}/actions/Send_email?{API}")
        print(f"email step: {send['properties']['status']}")
        return 0 if run["properties"]["status"] == "Succeeded" else 1
    finally:
        set_mode(a.app_rg, a.app_name, "off")


if __name__ == "__main__":
    sys.exit(main())
