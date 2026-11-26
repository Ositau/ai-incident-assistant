# AI incident assistant (Azure Logic Apps + Azure OpenAI)

When an Azure Monitor alert fires, this Logic App gathers the evidence from Log Analytics, asks Azure OpenAI to write a plain-English incident note (what's wrong, the likely cause with the actual error, the evidence, the impact and next steps), and emails it to the on-call engineer. It explains; it never takes action.

Every call the Logic App makes uses its **managed identity**: no API keys, no connection strings. Everything is deployed by **Terraform** through **GitHub Actions**, with the workflow definition kept in Git as plain JSON.

```
Azure Monitor alert ─▶ action group ─▶ Logic App (Consumption)
                                         ├─ reply 202 straight away (no duplicate alerts)
                                         ├─ Log Analytics: requests, exceptions, platform events (15 min)
                                         ├─ Azure OpenAI: incident note (strict JSON, temperature 0)
                                         ├─ fallback note if the AI call fails
                                         └─ email via Azure Communication Services
```

Step-by-step guide to build it yourself: [ositauche.com/ai-incident-assistant-azure-logic-apps-openai-terraform](https://ositauche.com/ai-incident-assistant-azure-logic-apps-openai-terraform/)

## What's here

| Path | What it is |
|---|---|
| `workflow/definition.json` | The Logic App, as code |
| `infra/` | Terraform: Logic App, email service, alert rules, action group, the Logic App's three roles |
| `scripts/bootstrap.sh` | One-time setup: resource groups, state storage, the GitHub sign-in identity with limited permissions |
| `tests/test_definition.py` | Static checks on the workflow (references, managed identity only, never takes action) |
| `tests/send_sample_alert.py` | Sends a sample alert to the deployed Logic App and checks the note it writes |
| `.github/workflows/deploy.yml` | PR: checks, plan, AI review of the plan. Main: apply, then the sample-alert test |

## Cost

Pennies: Logic Apps Consumption charges per action run (about 0.1p per incident), email is about £0.0002 per message, each log alert rule checked every 5 minutes is roughly $1.50 a month at list price (the only fixed cost), and the AI note costs a fraction of a penny.

Written by [Osita Uche](https://ositauche.com).
