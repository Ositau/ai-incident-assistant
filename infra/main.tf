# AI incident assistant: Azure Monitor alert -> Logic App -> evidence from Log Analytics ->
# Azure OpenAI writes an incident note -> email via Azure Communication Services.
# Every call the Logic App makes uses its managed identity. No keys or connection strings.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# ---------- Email: Azure Communication Services with an Azure-managed sending domain ----------

resource "azurerm_email_communication_service" "this" {
  name                = "ecs-incident-assistant"
  resource_group_name = data.azurerm_resource_group.this.name
  data_location       = var.email_data_location
  tags                = var.tags
}

# Azure gives this domain a random name ending in azurecomm.net. No DNS records needed.
resource "azurerm_email_communication_service_domain" "managed" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.this.id
  domain_management = "AzureManaged"
  tags              = var.tags
}

resource "azurerm_communication_service" "this" {
  name                = "acs-incident-assistant-${substr(md5(data.azurerm_resource_group.this.id), 0, 6)}"
  resource_group_name = data.azurerm_resource_group.this.name
  data_location       = var.email_data_location
  tags                = var.tags
}

resource "azurerm_communication_service_email_domain_association" "this" {
  communication_service_id = azurerm_communication_service.this.id
  email_service_domain_id  = azurerm_email_communication_service_domain.managed.id
}

# ---------- The Logic App (Consumption): definition kept in Git as workflow/definition.json ----------

resource "azapi_resource" "workflow" {
  type      = "Microsoft.Logic/workflows@2019-05-01"
  name      = "la-incident-assistant"
  location  = var.location
  parent_id = data.azurerm_resource_group.this.id
  tags      = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.logic_app.id]
  }

  body = {
    properties = {
      state      = "Enabled"
      definition = jsondecode(file("${path.module}/../workflow/definition.json"))
      parameters = {
        workspaceId      = { value = azapi_resource_action.workspace_customer_id.output.properties.customerId }
        appName          = { value = var.watched_app_name }
        openAiEndpoint   = { value = trimsuffix(var.openai_endpoint, "/") }
        openAiDeployment = { value = var.openai_deployment }
        acsEndpoint      = { value = "https://${azurerm_communication_service.this.hostname}" }
        senderAddress    = { value = "DoNotReply@${azurerm_email_communication_service_domain.managed.mail_from_sender_domain}" }
        recipient        = { value = var.alert_email }
        identityId       = { value = azurerm_user_assigned_identity.logic_app.id }
      }
    }
  }

}

# The Logs API needs the workspace's customer ID (a GUID), not its resource ID.
resource "azapi_resource_action" "workspace_customer_id" {
  type                   = "Microsoft.OperationalInsights/workspaces@2023-09-01"
  resource_id            = var.watched_workspace_id
  method                 = "GET"
  response_export_values = ["properties.customerId"]
}

# The Logic App runs as its own user-assigned identity. Its principal ID is fixed and known at plan
# time, so editing the workflow never touches the role assignments. (With a system-assigned identity
# read from the workflow's output, every workflow edit planned destroy-and-recreate of all three
# role assignments; the AI plan review caught it.)
resource "azurerm_user_assigned_identity" "logic_app" {
  name                = "id-incident-assistant"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = var.tags
}

locals {
  logic_app_principal = azurerm_user_assigned_identity.logic_app.principal_id
}

# ---------- What the Logic App's identity may do (and nothing else) ----------

resource "azurerm_role_assignment" "read_logs" {
  scope                = var.watched_workspace_id
  role_definition_name = "Log Analytics Reader"
  principal_id         = local.logic_app_principal
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "call_openai" {
  scope                = var.openai_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = local.logic_app_principal
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "send_email" {
  scope                = azurerm_communication_service.this.id
  role_definition_name = "Communication and Email Service Owner"
  principal_id         = local.logic_app_principal
  principal_type       = "ServicePrincipal"
}

# New role assignments take a minute or two to apply. Wait, so the post-deploy test doesn't run
# before the Logic App can read logs, call Azure OpenAI and send email.
resource "time_sleep" "roles" {
  create_duration = "90s"
  triggers = {
    principal = local.logic_app_principal
  }
  depends_on = [azurerm_role_assignment.read_logs, azurerm_role_assignment.call_openai, azurerm_role_assignment.send_email]
}

# ---------- Alerts -> action group -> Logic App ----------

# The action group calls the Logic App's trigger. Its URL contains a signature, so it is read
# here at deploy time and kept in state, never written into code or the pipeline log.
resource "azapi_resource_action" "callback_url" {
  type                             = "Microsoft.Logic/workflows/triggers@2019-05-01"
  resource_id                      = "${azapi_resource.workflow.id}/triggers/When_an_alert_fires"
  action                           = "listCallbackUrl"
  response_export_values           = ["value"]
  sensitive_response_export_values = ["value"]
}

resource "azurerm_monitor_action_group" "incident" {
  name                = "ag-incident-assistant"
  resource_group_name = data.azurerm_resource_group.this.name
  short_name          = "incident-ai"
  tags                = var.tags

  logic_app_receiver {
    name                    = "incident-assistant"
    resource_id             = azapi_resource.workflow.id
    callback_url            = azapi_resource_action.callback_url.sensitive_output.value
    use_common_alert_schema = true
  }
}

locals {
  alerts = {
    failing = {
      display     = "${var.watched_app_name}: requests failing"
      severity    = 1
      query       = <<-KQL
        AppRequests
        | where Success == false and toint(ResultCode) >= 500
      KQL
      aggregation = "Count"
      measure     = null
      threshold   = 0
    }
    slow = {
      display     = "${var.watched_app_name}: slow responses"
      severity    = 2
      query       = <<-KQL
        AppRequests
        | where Name !has "favicon"
        | project DurationMs
      KQL
      aggregation = "Average"
      measure     = "DurationMs"
      threshold   = 5000
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "watch" {
  for_each             = local.alerts
  name                 = "alert-${each.key}"
  display_name         = each.value.display
  resource_group_name  = data.azurerm_resource_group.this.name
  location             = var.location
  scopes               = [var.watched_workspace_id]
  severity             = each.value.severity
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  description          = "Watched by the AI incident assistant."
  tags                 = var.tags

  criteria {
    query                   = each.value.query
    time_aggregation_method = each.value.aggregation
    metric_measure_column   = each.value.measure
    operator                = "GreaterThan"
    threshold               = each.value.threshold

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.incident.id]
  }
}
