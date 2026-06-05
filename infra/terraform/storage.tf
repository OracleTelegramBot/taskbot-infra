# Namespace de Object Storage de la tenancy (cada tenancy tiene uno)
data "oci_objectstorage_namespace" "ns" {
  compartment_id = oci_identity_compartment.taskbot.id
}

# Bucket privado para el Wallet de la Autonomous DB
resource "oci_objectstorage_bucket" "wallet" {
  compartment_id = oci_identity_compartment.taskbot.id
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${local.name_prefix}-wallet"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled" # útil por si subes una versión nueva del wallet
  freeform_tags  = local.common_tags
}

output "wallet_bucket_name" {
  value = oci_objectstorage_bucket.wallet.name
}

output "wallet_bucket_namespace" {
  value = data.oci_objectstorage_namespace.ns.namespace
}
