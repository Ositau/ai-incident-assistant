variable "resource_group_name" {
  description = "Resource group for the incident assistant (created by scripts/bootstrap.sh)."
  type        = string
  default     = "rg-incident-assistant"
}

variable "location" {
  type    = string
  default = "swedencentral"
}

variable "email_data_location" {
  description = "Where Azure Communication Services stores email data at rest."
  type        = string
  default     = "UK"
}

# ---- What to watch ----

variable "watched_workspace_id" {
  description = "Resource ID of the Log Analytics workspace that holds the watched app's logs (AppRequests, AppExceptions, Container Apps logs)."
  type        = string
}

variable "watched_app_name" {
  description = "A friendly name for the watched app, used in alert names and emails."
  type        = string
  default     = "Policy Assistant"
}

# ---- Azure OpenAI used to write the incident note ----

variable "openai_account_id" {
  description = "Resource ID of the Azure OpenAI account."
  type        = string
}

variable "openai_endpoint" {
  description = "Endpoint of the Azure OpenAI account, e.g. https://my-openai.openai.azure.com/"
  type        = string
}

variable "openai_deployment" {
  type    = string
  default = "gpt-4o-mini"
}

# ---- Who gets the incident notes ----

variable "alert_email" {
  description = "Where incident notes are sent."
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    project    = "ai-incident-assistant"
    managed_by = "terraform"
  }
}
