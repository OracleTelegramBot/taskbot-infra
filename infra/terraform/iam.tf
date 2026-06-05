# =========================================================
# Compartment del proyecto
# Contenedor lógico que agrupa todos los recursos de TaskBot.
# Todo lo que se cree en los demás archivos referenciará este OCID.
# =========================================================
resource "oci_identity_compartment" "taskbot" {
  compartment_id = var.parent_compartment_ocid
  name           = "${local.name_prefix}-compartment"
  description    = "Compartment que aloja toda la infraestructura del proyecto TaskBot"

  # Permite que `terraform destroy` marque el compartment para borrado.
  # Nota: en OCI el borrado es asíncrono (~6 min) y el compartment queda
  # en estado DELETED, no desaparece de inmediato del listado.
  enable_delete = true

  freeform_tags = local.common_tags
}

# =========================================================
# Políticas de servicio para OKE
# Permiten que el servicio OKE administre red y load balancers
# dentro del compartment del proyecto. Estas políticas se crean
# en el compartment padre (tenancy root) para que tengan alcance
# sobre el compartment hijo.
# =========================================================
resource "oci_identity_policy" "oke_service" {
  compartment_id = var.parent_compartment_ocid
  name           = "${local.name_prefix}-oke-service-policy"
  description    = "Permisos requeridos por el servicio OKE para operar dentro del compartment de TaskBot"

  statements = [
    # Crear y administrar VCN, subnets, route tables, security lists, NSGs, gateways
    "Allow service OKE to manage virtual-network-family in compartment ${oci_identity_compartment.taskbot.name}",

    # Crear los Load Balancers cuando se expongan Services de tipo LoadBalancer
    "Allow service OKE to manage load-balancers in compartment ${oci_identity_compartment.taskbot.name}",

    # Adjuntar nodos a subnets, gestionar VNICs y IPs privadas de los pods/nodos
    "Allow service OKE to use subnets in compartment ${oci_identity_compartment.taskbot.name}",
    "Allow service OKE to use vnics in compartment ${oci_identity_compartment.taskbot.name}",
    "Allow service OKE to use private-ips in compartment ${oci_identity_compartment.taskbot.name}",
    "Allow service OKE to use network-security-groups in compartment ${oci_identity_compartment.taskbot.name}",
  ]

  freeform_tags = local.common_tags
}


# =========================================================
# Dynamic Group para los worker nodes de OKE
# Agrupa lógicamente a todas las instancias compute del
# compartment de TaskBot. Esto permite que se autentiquen como
# "instance principals" frente a OCI y reciban permisos IAM.
# Es el mecanismo que va a usar External Secrets Operator
# para leer secretos del Vault sin necesidad de credenciales.
#
# Nota: los Dynamic Groups SIEMPRE viven en el tenancy root,
# nunca dentro de un compartment hijo.
# =========================================================
resource "oci_identity_dynamic_group" "oke_nodes" {
  compartment_id = var.parent_compartment_ocid
  name           = "${local.name_prefix}-oke-nodes-dg"
  description    = "Worker nodes del cluster OKE de TaskBot"

  # Matcher: cualquier instancia compute que viva en el compartment
  # de TaskBot pertenece a este grupo automáticamente.
  matching_rule = "ALL {instance.compartment.id = '${oci_identity_compartment.taskbot.id}'}"

  freeform_tags = local.common_tags
}

# =========================================================
# Política IAM — el Dynamic Group puede leer secretos del Vault
# Dos statements:
#   1. Leer la familia de secretos completa (incluye contenido de versiones)
#   2. Usar las llaves de cifrado (necesario porque los secretos están
#      cifrados con la master key; descifrarlos requiere "use keys")
# =========================================================
resource "oci_identity_policy" "oke_nodes_vault_access" {
  compartment_id = oci_identity_compartment.taskbot.id
  name           = "${local.name_prefix}-oke-nodes-vault-access"
  description    = "Permite a los worker nodes leer secretos del Vault y descifrar con la master key"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to read vaults in compartment ${oci_identity_compartment.taskbot.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to read secret-family in compartment ${oci_identity_compartment.taskbot.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to use keys in compartment ${oci_identity_compartment.taskbot.name}",

    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to read objects in compartment ${oci_identity_compartment.taskbot.name} where target.bucket.name='${local.name_prefix}-wallet'",
  ]
}
