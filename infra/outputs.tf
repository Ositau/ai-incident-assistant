output "logic_app_id" {
  value = azapi_resource.workflow.id
}

output "logic_app_principal_id" {
  value = local.logic_app_principal
}

output "sender_address" {
  value = "DoNotReply@${azurerm_email_communication_service_domain.managed.mail_from_sender_domain}"
}
