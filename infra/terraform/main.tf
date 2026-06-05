# =========================================================
# Configuración del provider de OCI
# Lee credenciales de ~/.oci/config (profile DEFAULT)
# =========================================================
provider "oci" {
  config_file_profile = "DEFAULT"
  region              = var.region
}

# =========================================================
# Valores compartidos por todos los módulos
# Los consumen iam.tf, network.tf, oke.tf, vault.tf, etc.
# =========================================================
locals {
  name_prefix = var.project_name

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
