# =========================================================
# Región de OCI (consumida por el provider)
# =========================================================
variable "region" {
  description = "Región de OCI donde se provisionarán todos los recursos"
  type        = string
  default     = "mx-queretaro-1"
}

# =========================================================
# Metadata del proyecto (prefijo de nombres + tags)
# =========================================================
variable "project_name" {
  description = "Nombre corto del proyecto. Se usa como prefijo de todo recurso (ej. \"taskbot\" produce \"taskbot-vcn\", \"taskbot-oke-cluster\")"
  type        = string
  default     = "taskbot"
}

variable "environment" {
  description = "Etiqueta del entorno de despliegue, usada en tags (ej. \"prod\", \"dev\")"
  type        = string
  default     = "prod"
}

variable "parent_compartment_ocid" {
  description = "OCID del compartment bajo el cual se creará el compartment del proyecto. Normalmente es la raíz del tenancy."
  type        = string
}

# =========================================================
# Red (consumidas por network.tf)
# =========================================================
variable "vcn_cidr" {
  description = "Rango CIDR de la VCN del proyecto"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Rango CIDR de la subnet pública (Load Balancers + endpoint K8s API)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "Rango CIDR de la subnet privada (worker nodes de OKE)"
  type        = string
  default     = "10.0.1.0/24"
}

# =========================================================
# OKE Cluster (consumidas por oke.tf)
# =========================================================
variable "node_shape" {
  description = "Shape de cómputo para los worker nodes de OKE"
  type        = string
  default     = "VM.Standard.E3.Flex"
}

variable "node_ocpus" {
  description = "Número de OCPUs por nodo (1 OCPU = 2 vCPUs en AMD/Intel)"
  type        = number
  default     = 2
}

variable "node_memory_gb" {
  description = "Memoria RAM por nodo en GB"
  type        = number
  default     = 16
}

variable "node_count" {
  description = "Número total de worker nodes en el pool"
  type        = number
  default     = 2
}

variable "secret_values" {
  description = "Valores reales de los secretos del Vault. NUNCA commitear este archivo de tfvars."
  type = object({
    jwt_secret         = string
    openai_api_key     = string
    telegram_bot_token = string
    db_admin_username  = string
    db_admin_password  = string
    wallet_password    = string
  })
  sensitive = true
}
