# =========================================================
# Vault — contenedor de secretos cifrados
# Usa tipo DEFAULT (HSM compartido, GRATIS). El otro tipo
# (VIRTUAL_PRIVATE) tiene HSM dedicado pero cuesta ~$1500/mes,
# overkill total para este proyecto.
# =========================================================
resource "oci_kms_vault" "taskbot" {
  compartment_id = oci_identity_compartment.taskbot.id
  display_name   = "${local.name_prefix}-vault"
  vault_type     = "DEFAULT"

  freeform_tags = local.common_tags
}

# =========================================================
# Espera de propagación de DNS del Vault
# El management_endpoint del Vault recién creado tarda 1-3 min
# en resolverse vía DNS. Sin este sleep, los recursos que lo
# consumen (la key, los secretos) fallan con "no such host".
# =========================================================
resource "time_sleep" "wait_for_vault_dns" {
  depends_on      = [oci_kms_vault.taskbot]
  create_duration = "120s"
}

# =========================================================
# Master Encryption Key — cifra todos los secretos del Vault
# protection_mode = SOFTWARE: cifrado por software (gratis).
# HSM cuesta ~$22/mes por llave. Para una app de este tamaño,
# software es totalmente apropiado.
# =========================================================
resource "oci_kms_key" "taskbot" {
  compartment_id      = oci_identity_compartment.taskbot.id
  display_name        = "${local.name_prefix}-master-key"
  management_endpoint = oci_kms_vault.taskbot.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32 # AES-256
  }

  depends_on = [time_sleep.wait_for_vault_dns]

  freeform_tags = local.common_tags
}

# =========================================================
# Definición de los secretos a gestionar
# Solo las claves y descripciones — los valores se inyectan
# DESPUÉS desde la consola de OCI (ver nota al final).
# =========================================================
locals {
  secrets = {
    "jwt-secret" = {
      description = "Clave de firma para tokens JWT de autenticación (auth-service)"
      value       = var.secret_values.jwt_secret
    }
    "openai-api-key" = {
      description = "API key de OpenAI gpt-4o-mini (ai-service)"
      value       = var.secret_values.openai_api_key
    }
    "telegram-bot-token" = {
      description = "Token del bot de Telegram (telegram-service)"
      value       = var.secret_values.telegram_bot_token
    }
    "db-admin-username" = {
      description = "Usuario admin de la Autonomous Database gestiondetareasbd_tp"
      value       = var.secret_values.db_admin_username
    }
    "db-admin-password" = {
      description = "Contraseña admin de la Autonomous Database gestiondetareasbd_tp"
      value       = var.secret_values.db_admin_password
    }
    "wallet-password" = {
      description = "Password del Wallet zip de la Autonomous DB"
      value       = var.secret_values.wallet_password
    }
  }
}

# =========================================================
# Secretos del Vault
# Se crean con valor placeholder "REPLACE_ME". El bloque
# lifecycle.ignore_changes evita que Terraform sobrescriba el
# valor real que actualices después desde la consola de OCI.


resource "oci_vault_secret" "taskbot" {
  for_each = local.secrets

  compartment_id = oci_identity_compartment.taskbot.id
  vault_id       = oci_kms_vault.taskbot.id
  key_id         = oci_kms_key.taskbot.id
  secret_name    = "${local.name_prefix}-${each.key}"
  description    = each.value.description

  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value.value)
  }

  lifecycle {
    ignore_changes = [secret_content]
  }

  freeform_tags = local.common_tags
}

# =========================================================
# =========================================================
# Outputs
# =========================================================
output "vault_id" {
  description = "OCID del Vault que contiene todos los secretos"
  value       = oci_kms_vault.taskbot.id
}

output "secret_ocids" {
  description = "Mapa de nombre → OCID de cada secreto. Útil para referenciar desde Kubernetes."
  value       = { for k, v in oci_vault_secret.taskbot : k => v.id }
}
