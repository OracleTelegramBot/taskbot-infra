# =========================================================
# VCN (Virtual Cloud Network)
# Red privada virtual donde vivirán todos los recursos de red:
# subnets, gateways, nodos OKE, Load Balancers, etc.
# =========================================================
resource "oci_core_vcn" "taskbot" {
  compartment_id = oci_identity_compartment.taskbot.id
  display_name   = "${local.name_prefix}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "taskbot" # habilita DNS interno: <host>.<subnet>.taskbot.oraclevcn.com

  freeform_tags = local.common_tags
}

# =========================================================
# Internet Gateway
# Permite tráfico bidireccional entre la subnet pública e Internet.
# Lo usan el Load Balancer de producción y el endpoint público
# de la API de Kubernetes.
# =========================================================
resource "oci_core_internet_gateway" "taskbot" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-igw"
  enabled        = true

  freeform_tags = local.common_tags
}

# =========================================================
# NAT Gateway
# Permite que los nodos de la subnet privada hagan llamadas
# salientes a Internet (pull de imágenes desde GHCR, llamadas
# a OpenAI API, Telegram API, etc.) sin estar expuestos.
# =========================================================
resource "oci_core_nat_gateway" "taskbot" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-nat"

  freeform_tags = local.common_tags
}

# =========================================================
# Service Gateway
# Permite que la subnet privada acceda a servicios nativos de OCI
# (Object Storage, Logging, Monitoring, Vault, Autonomous DB) sin
# pasar por Internet. Importante para que el agente de OCI Logging
# y el wallet de la Autonomous DB resuelvan rápido y de forma segura.
# =========================================================
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "taskbot" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-sgw"

  services {
    service_id = data.oci_core_services.all_oci_services.services[0].id
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Route Table — Subnet pública
# Tráfico hacia Internet → Internet Gateway
# =========================================================
resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.taskbot.id
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Route Table — Subnet privada
# Tráfico hacia Internet → NAT Gateway (solo salida)
# Tráfico hacia servicios OCI → Service Gateway (interno)
# =========================================================
resource "oci_core_route_table" "private" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.taskbot.id
  }

  route_rules {
    destination       = data.oci_core_services.all_oci_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.taskbot.id
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Security List — Subnet pública
# Reglas a nivel de subnet para Load Balancers, endpoint K8s API
# y comunicación interna con la subnet privada (worker nodes).
#
# NOTA: el OCI Cloud Controller Manager (que vive dentro del cluster)
# modifica estas reglas dinámicamente para abrir NodePorts cuando
# se crean Services tipo LoadBalancer. El lifecycle.ignore_changes
# al final hace que Terraform deje de pelearse con el CCM por
# esas reglas.
# =========================================================
resource "oci_core_security_list" "public" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-public-sl"

  # ---------- Egress: todo permitido ----------
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # ---------- Ingress ----------

  # Tráfico interno completo desde dentro de la VCN.
  # OKE requiere que los worker nodes (subnet privada) alcancen el endpoint
  # del API server en múltiples puertos: 6443 (kubectl), 12250 (registro de
  # nodos), entre otros. Abrir todo el tráfico TCP entre componentes internos
  # de la VCN es seguro porque la VCN es privada y no se expone a Internet.
  ingress_security_rules {
    source    = var.vcn_cidr
    protocol  = "6" # TCP
    stateless = false
  }

  # HTTPS desde Internet (tráfico real de la aplicación)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6" # TCP
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # HTTP desde Internet (redirect a HTTPS + challenges de cert-manager)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6" # TCP
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # API de Kubernetes (kubectl local, GitHub Actions)
  # Se puede restringir a IPs específicas más adelante.
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "6" # TCP
    stateless = false
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # Path MTU Discovery (evita black-holes de paquetes grandes)
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1" # ICMP
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Terraform sigue siendo dueño de la creación de la security list,
  # pero las reglas dentro las gestiona el CCM dinámicamente.
  lifecycle {
    ignore_changes = [
      ingress_security_rules,
      egress_security_rules,
    ]
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Security List — Subnet privada
# Reglas para los worker nodes de OKE.
# Permite comunicación libre dentro de la VCN y salida total
# vía NAT/SGW.
#
# Mismo patrón: el CCM agrega aquí reglas para que el LB pueda
# alcanzar los nodos en los NodePorts asignados. Ignoramos cambios.
# =========================================================
resource "oci_core_security_list" "private" {
  compartment_id = oci_identity_compartment.taskbot.id
  vcn_id         = oci_core_vcn.taskbot.id
  display_name   = "${local.name_prefix}-private-sl"

  # ---------- Egress: todo permitido ----------
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # ---------- Ingress ----------

  # Todo el tráfico desde dentro de la VCN:
  # - LB → nodos (NodePort, health checks)
  # - control plane → kubelet
  # - nodo → nodo (Flannel overlay, pod-to-pod)
  ingress_security_rules {
    source    = var.vcn_cidr
    protocol  = "all"
    stateless = false
  }

  # Path MTU Discovery
  ingress_security_rules {
    source    = "0.0.0.0/0"
    protocol  = "1" # ICMP
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Mismo motivo que en la pública: el CCM gestiona reglas dinámicas
  # para NodePorts y health checks de Load Balancers.
  lifecycle {
    ignore_changes = [
      ingress_security_rules,
      egress_security_rules,
    ]
  }

  freeform_tags = local.common_tags
}

# =========================================================
# Subnet pública — Load Balancers + endpoint K8s API
# Regional (no atada a un AD específico, alta disponibilidad).
# =========================================================
resource "oci_core_subnet" "public" {
  compartment_id    = oci_identity_compartment.taskbot.id
  vcn_id            = oci_core_vcn.taskbot.id
  display_name      = "${local.name_prefix}-public-subnet"
  cidr_block        = var.public_subnet_cidr
  dns_label         = "public"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]

  # Recursos en esta subnet pueden tener IP pública
  prohibit_public_ip_on_vnic = false

  freeform_tags = local.common_tags
}

# =========================================================
# Subnet privada — Worker nodes de OKE
# Sin IPs públicas. Salida a Internet vía NAT.
# =========================================================
resource "oci_core_subnet" "private" {
  compartment_id    = oci_identity_compartment.taskbot.id
  vcn_id            = oci_core_vcn.taskbot.id
  display_name      = "${local.name_prefix}-private-subnet"
  cidr_block        = var.private_subnet_cidr
  dns_label         = "private"
  route_table_id    = oci_core_route_table.private.id
  security_list_ids = [oci_core_security_list.private.id]

  # Prohíbe asignar IPs públicas: los nodos son solo internos
  prohibit_public_ip_on_vnic = true

  freeform_tags = local.common_tags
}
