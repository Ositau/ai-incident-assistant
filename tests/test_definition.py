"""Static checks on the Logic App definition (no Azure needed).

A Logic App definition is a big JSON file, so a typo in an action name inside runAfter or
an expression only shows up when the workflow runs. These checks catch that earlier.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

DEF = json.loads((Path(__file__).resolve().parent.parent / "workflow" / "definition.json").read_text(encoding="utf-8"))


def all_actions(actions: dict) -> dict:
    out = {}
    for name, a in actions.items():
        out[name] = a
        out.update(all_actions(a.get("actions", {})))
        out.update(all_actions(a.get("else", {}).get("actions", {})))
    return out


ACTIONS = all_actions(DEF["actions"])
TEXT = json.dumps(DEF)


def test_every_run_after_points_at_a_real_action():
    for name, a in ACTIONS.items():
        for dep in a.get("runAfter", {}):
            assert dep in ACTIONS, f"{name} runs after unknown action {dep}"


def test_every_referenced_action_exists():
    for ref in set(re.findall(r"(?:outputs|body|actions)\('([^']+)'\)", TEXT)):
        assert ref in ACTIONS, f"expression refers to unknown action {ref}"


def test_every_parameter_is_declared():
    declared = set(DEF["parameters"])
    for ref in set(re.findall(r"parameters\('([^']+)'\)", TEXT)):
        assert ref in declared, f"undeclared parameter {ref}"


def test_every_http_call_uses_the_user_assigned_identity():
    for name, a in ACTIONS.items():
        if a["type"] == "Http":
            auth = a["inputs"]["authentication"]
            assert auth["type"] == "ManagedServiceIdentity", name
            assert auth["identity"] == "@parameters('identityId')", name


def test_trigger_is_answered_straight_away():
    # Azure Monitor action groups retry slow webhooks, which would send duplicate emails.
    assert DEF["actions"]["Acknowledge"]["type"] == "Response"
    assert DEF["actions"]["Acknowledge"]["runAfter"] == {}


def test_ai_answer_has_a_strict_schema_and_temperature_zero():
    body = ACTIONS["Ask_OpenAI"]["inputs"]["body"]
    assert body["temperature"] == 0
    assert body["response_format"]["json_schema"]["strict"] is True


def test_ai_failure_still_sends_a_note():
    assert ACTIONS["Fallback_note"]["runAfter"] == {"Ask_OpenAI": ["Failed", "TimedOut"]}


def test_dry_run_skips_the_email():
    cond = ACTIONS["Send_unless_dry_run"]
    assert "Send_email" in cond["actions"] and cond["else"]["actions"] == {}


def test_the_assistant_never_takes_action():
    # Only reads (logs), one AI call and one email: no other HTTP methods or targets.
    allowed = (
        "https://api.loganalytics.io/v1/workspaces/",          # read logs (the query API is POST)
        "@{parameters('openAiEndpoint')}/openai/deployments/",  # ask the model
        "@{parameters('acsEndpoint')}/emails:send",             # send the note
    )
    for name, a in ACTIONS.items():
        if a["type"] == "Http":
            assert a["inputs"]["method"] == "POST", name
            assert a["inputs"]["uri"].startswith(allowed), f"{name} calls something unexpected: {a['inputs']['uri']}"


def test_resolved_alerts_get_a_short_email_and_no_ai_call():
    # A "Resolved" notice used to run the whole investigation and read like a new incident.
    branch = DEF["actions"]["Is_resolved"]
    assert branch["runAfter"] == {"Alert": ["Succeeded"]}
    assert DEF["actions"]["Window"]["runAfter"] == {"Is_resolved": ["Succeeded"]}
    inner = branch["actions"]
    assert "Send_resolved_email" in inner["Resolved_unless_dry_run"]["actions"]
    assert inner["Stop_after_resolved"]["type"] == "Terminate"
    assert inner["Stop_after_resolved"]["inputs"]["runStatus"] == "Succeeded"
    assert "Ask_OpenAI" not in all_actions(inner)
