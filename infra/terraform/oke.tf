# =========================================================
# Data sources — opciones del cluster + imagen del nodo
# =========================================================

# Availability Domains de la región (para distribuir nodos)
data "oci_identity_availability_domains" "ads" {
  compartment_id = oci_identity_compartment.taskbot.id
}

# Versiones de Kubernetes soportadas por OKE
data "oci_containerengine_cluster_option" "k8s" {
  cluster_option_id = "all"
}

# Catálogo completo de imágenes OKE-blessed (incluye todas las variantes:
# x86_64 estándar, ARM/aarch64, GPU, OL 7.9 — filtramos en el local).
data "oci_containerengine_node_pool_option" "node" {
  node_pool_option_id = "all"
  compartment_id      = oci_identity_compartment.taskbot.id
}

# =========================================================
# Locales — selección de versión e imagen
# =========================================================
locals {
  # Versión de Kubernetes más reciente disponible en OKE (formato "v1.36.0")
  kubernetes_version = reverse(sort(data.oci_containerengine_cluster_option.k8s.kubernetes_versions))[0]

  # Misma versión sin el prefijo "v" para matchear nombres de imágenes
  kubernetes_version_bare = trimprefix(local.kubernetes_version, "v")

  # Selecciona la imagen Oracle Linux 8 x86_64 estándar para la versión de
  # Kubernetes elegida. OKE publica 4 variantes por versión:
  #   - estándar x86_64    ← la que queremos (compatible con E3.Flex/E4.Flex/E5.Flex)
  #   - aarch64            → solo para shapes ARM (A1.Flex)
  #   - Gen2-GPU           → solo para shapes con GPU
  #   - Oracle-Linux-7.9   → OS legacy
  # El regex matchea OL 8, y los dos exclude descartan ARM y GPU.
  oke_node_image_id = [
    for src in data.oci_containerengine_node_pool_option.node.sources :
    src.image_id
    if(
      length(regexall("Oracle-Linux-8.*OKE-${local.kubernetes_version_bare}", src.source_name)) > 0
      && length(regexall("aarch64", src.source_name)) == 0
      && length(regexall("GPU", src.source_name)) == 0
    )
  ][0]
}

# =========================================================
# Cluster OKE
# =========================================================
resource "oci_containerengine_cluster" "taskbot" {
  compartment_id     = oci_identity_compartment.taskbot.id
  name               = "${local.name_prefix}-oke-cluster"
  kubernetes_version = local.kubernetes_version
  vcn_id             = oci_core_vcn.taskbot.id
  type               = "BASIC_CLUSTER" # Control plane gratuito. ENHANCED suma features avanzadas y cuesta.

  # Endpoint público de la API de Kubernetes, en la subnet pública.
  # Permite que kubectl local y GitHub Actions hablen al cluster.
  endpoint_config {
    subnet_id            = oci_core_subnet.public.id
    is_public_ip_enabled = true
  }

  options {
    # Subnet donde OKE crea los Load Balancers para Services type=LoadBalancer
    service_lb_subnet_ids = [oci_core_subnet.public.id]

    # CNI: Flannel overlay. Los pods viven en su propio CIDR, no consumen IPs de la VCN.
    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }

    # Add-ons heredados deshabilitados (deprecados / riesgo de seguridad)
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Node Pool — worker nodes
# =========================================================
resource "oci_containerengine_node_pool" "taskbot" {
  compartment_id     = oci_identity_compartment.taskbot.id
  cluster_id         = oci_containerengine_cluster.taskbot.id
  name               = "${local.name_prefix}-oke-nodepool"
  kubernetes_version = local.kubernetes_version
  node_shape         = var.node_shape

  # Tamaño de cada nodo
  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  # Imagen de boot del nodo (Oracle Linux 8 + OKE preconfigurado)
  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.oke_node_image_id
    boot_volume_size_in_gbs = 50
  }

  # Tamaño del pool + ubicación de los nodos
  node_config_details {
    size = var.node_count

    # Distribuye los nodos en todas las ADs disponibles (alta disponibilidad)
    dynamic "placement_configs" {
      for_each = data.oci_identity_availability_domains.ads.availability_domains
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = oci_core_subnet.private.id
      }
    }
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Outputs útiles para el siguiente paso (kubeconfig + manifests)
# =========================================================
output "oke_cluster_id" {
  description = "OCID del cluster OKE. Útil para generar el kubeconfig."
  value       = oci_containerengine_cluster.taskbot.id
}

output "oke_cluster_endpoint" {
  description = "Endpoint público de la API de Kubernetes"
  value       = oci_containerengine_cluster.taskbot.endpoints[0].public_endpoint
}
