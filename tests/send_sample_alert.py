"""Send a sample alert to the deployed Logic App and check the incident note it writes.

Used by the pipeline after every deploy, and by hand while testing. It reads the trigger URL
from Azure (so it never sits in code or logs), posts an alert in Azure Monitor's common alert
schema, waits for the run, and checks the note. With --dry-run (the default) no email is sent.

  python tests/send_sample_alert.py --workflow-id <resource id> [--send-email] [--rule "..."]

Needs an Azure sign-in that can manage the Logic App (Contributor on its resource group).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import time
import urllib.request

API = "api-version=2019-05-01"


def az_rest(method: str, url: str) -> dict:
    out = subprocess.run(["az", "rest", "--method", method, "--url", url, "-o", "json"],
                         capture_output=True, text=True, check=True, shell=sys.platform == "win32").stdout
    return json.loads(out or "{}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--workflow-id", required=True)
    p.add_argument("--rule", default="Policy Assistant: requests failing")
    p.add_argument("--send-email", action="store_true", help="really send the email (default: dry run)")
    p.add_argument("--timeout", type=int, default=180)
    a = p.parse_args()

    base = f"https://management.azure.com{a.workflow_id}"
    url = az_rest("POST", f"{base}/triggers/When_an_alert_fires/listCallbackUrl?{API}")["value"]

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    alert = {
        "schemaId": "azureMonitorCommonAlertSchema",
        "data": {
            "essentials": {
                "alertRule": a.rule,
                "severity": "Sev1",
                "monitorCondition": "Fired",
                "firedDateTime": now.isoformat().replace("+00:00", "Z"),
                "description": "Sample alert sent by tests/send_sample_alert.py",
            },
            "customProperties": {"dryRun": "false" if a.send_email else "true"},
        },
    }
    started = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=5)
    req = urllib.request.Request(url, data=json.dumps(alert).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        print(f"Trigger answered {r.status}")
        assert r.status == 202, "the trigger should answer 202 straight away"

    # Find this run and wait for it to finish.
    deadline = time.time() + a.timeout
    run = None
    while time.time() < deadline:
        runs = az_rest("GET", f"{base}/runs?{API}&$top=5")["value"]
        mine = [x for x in runs if dt.datetime.fromisoformat(x["properties"]["startTime"].replace("Z", "+00:00")[:26] + "+00:00") >= started]
        if mine and mine[-1]["properties"]["status"] not in ("Running", "Waiting"):
            run = mine[-1]
            break
        time.sleep(5)
    assert run, "the run didn't finish in time"
    status = run["properties"]["status"]
    print(f"Run {run['name']}: {status}")

    note_action = az_rest("GET", f"{base}/runs/{run['name']}/actions/Incident_note?{API}")
    with urllib.request.urlopen(note_action["properties"]["outputsLink"]["uri"]) as r:
        note = json.loads(r.read())["body"]
    print(json.dumps(note, indent=2))

    send = az_rest("GET", f"{base}/runs/{run['name']}/actions/Send_unless_dry_run?{API}")
    ai = az_rest("GET", f"{base}/runs/{run['name']}/actions/Ask_OpenAI?{API}")

    problems = []
    if status != "Succeeded":
        problems.append(f"run status {status}")
    if ai["properties"]["status"] != "Succeeded":
        problems.append("the AI call failed, the note is the fallback")
    for key in ("title", "summary", "likely_cause", "evidence", "impact", "next_steps", "confidence"):
        if not note.get(key):
            problems.append(f"note has no {key}")
    if note.get("confidence") not in ("low", "medium", "high"):
        problems.append("confidence is not low/medium/high")
    if send["properties"]["status"] != "Succeeded":
        problems.append(f"email step {send['properties']['status']}")

    if problems:
        print("FAILED: " + "; ".join(problems))
        return 1
    print("PASSED: the incident note has every part" + ("" if a.send_email else " (dry run, no email sent)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
