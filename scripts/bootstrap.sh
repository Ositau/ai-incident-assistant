#!/usr/bin/env bash
# One-time setup, run by a person with Owner on the subscription (or on the resource groups used).
# Creates: the resource group, Terraform state storage, and the GitHub Actions sign-in identity
# (workload identity federation, no secret) with only the permissions the pipeline needs.
#
# Usage:
#   GITHUB_OWNER=<you> GITHUB_REPO=ai-incident-assistant \
#   WATCHED_RG=rg-policy-assistant-demo ./scripts/bootstrap.sh
#
# On Git Bash for Windows, run `export MSYS_NO_PATHCONV=1` first, or /subscriptions/... paths get rewritten.
set -euo pipefail

LOCATION="${LOCATION:-swedencentral}"
RG="${RG:-rg-incident-assistant}"
STATE_RG="${STATE_RG:-rg-incident-assistant-tfstate}"
WATCHED_RG="${WATCHED_RG:?resource group of the app to watch (its Log Analytics workspace and Azure OpenAI)}"
GITHUB_OWNER="${GITHUB_OWNER:?your GitHub user or org}"
GITHUB_REPO="${GITHUB_REPO:-ai-incident-assistant}"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "Resource providers (the pipeline identity can't register them itself)"
for ns in Microsoft.Communication Microsoft.Logic Microsoft.Insights Microsoft.OperationalInsights Microsoft.Storage; do
  az provider register --namespace "$ns" --wait -o none
done

echo "Resource groups"
az group create -n "$RG" -l "$LOCATION" -o none
az group create -n "$STATE_RG" -l "$LOCATION" -o none
RG_ID=$(az group show -n "$RG" --query id -o tsv)
WATCHED_RG_ID=$(az group show -n "$WATCHED_RG" --query id -o tsv)

echo "Terraform state storage (Entra ID auth only, no keys)"
STATE_SA="${STATE_SA:-stincident$(echo -n "$SUB_ID" | md5sum | cut -c1-8)}"
az storage account create -n "$STATE_SA" -g "$STATE_RG" -l "$LOCATION" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false -o none
STATE_SA_ID=$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$STATE_SA_ID" -o none
sleep 30   # let the role apply before creating the container with Entra ID auth
az storage container create -n tfstate --account-name "$STATE_SA" --auth-mode login -o none

echo "GitHub Actions identity (no secret)"
APP_NAME="AI incident assistant (GitHub Actions)"
# Safe to re-run: reuse the app registration if it already exists.
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
[ -n "$APP_ID" ] || APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID" -o none 2>/dev/null || true
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# GitHub's token subject includes the owner and repository IDs: repo:<owner>@<id>/<repo>@<id>:<context>
read -r OWNER_ID REPO_ID < <(curl -s "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['owner']['id'], r['id'])" | tr -d '\r')
# (tr strips the carriage return Python adds on Windows; otherwise it ends up inside the JSON below.)
PREFIX="repo:$GITHUB_OWNER@$OWNER_ID/$GITHUB_REPO@$REPO_ID"
for cred in "pull-requests|$PREFIX:pull_request" "main|$PREFIX:ref:refs/heads/main"; do
  name="${cred%%|*}"; subject="${cred#*|}"
  if az ad app federated-credential show --id "$APP_ID" --federated-credential-id "$name" -o none 2>/dev/null; then continue; fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$name\", \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$subject\", \"audiences\": [\"api://AzureADTokenExchange\"]}" -o none
done

echo "Permissions"
assign() { az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal --role "$1" --scope "$2" ${3:+--condition "$3" --condition-version 2.0} -o none; }

# Create and change everything in its own resource group.
assign "Contributor" "$RG_ID"
# Read the watched app's resources (workspace and Azure OpenAI) to plan and to set up alerts on them.
assign "Reader" "$WATCHED_RG_ID"
# Call Azure OpenAI for the AI review of each pull request's plan.
assign "Cognitive Services OpenAI User" "$WATCHED_RG_ID"
assign "Storage Blob Data Contributor" "$STATE_SA_ID/blobServices/default/containers/tfstate"

# Hand out only the three roles the Logic App needs, nowhere else.
role_guid() { az role definition list --name "$1" --query "[0].name" -o tsv; }
ROLES="$(role_guid 'Log Analytics Reader'), $(role_guid 'Cognitive Services OpenAI User'), $(role_guid 'Communication and Email Service Owner')"
CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ROLES})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ROLES}))"
assign "Role Based Access Control Administrator" "$RG_ID" "$CONDITION"
assign "Role Based Access Control Administrator" "$WATCHED_RG_ID" "$CONDITION"

cat <<EOF

Done. Add these as GitHub repository variables (Settings > Secrets and variables > Actions > Variables):
  AZURE_CLIENT_ID        $APP_ID
  AZURE_TENANT_ID        $TENANT_ID
  AZURE_SUBSCRIPTION_ID  $SUB_ID
  TF_STATE_RG            $STATE_RG
  TF_STATE_ACCOUNT       $STATE_SA
EOF
