# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

terraform {
  required_providers {
    # We need to specify the provider source in each module until we publish it
    # to the public registry
    enos = {
      source  = "app.terraform.io/hashicorp-qti/enos"
      version = ">= 0.3.24"
    }
  }
}

data "aws_vpc" "vpc" {
  id = var.vpc_id
}

data "aws_subnets" "vpc" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_iam_policy_document" "target" {
  statement {
    resources = ["*"]

    actions = [
      "ec2:DescribeInstances",
      "secretsmanager:*"
    ]
  }

  dynamic "statement" {
    for_each = var.seal_key_names

    content {
      resources = [statement.value]

      actions = [
        "kms:DescribeKey",
        "kms:ListKeys",
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ]
    }
  }
}

data "aws_iam_policy_document" "target_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "enos_environment" "localhost" {}

resource "random_string" "random_cluster_name" {
  length  = 8
  lower   = true
  upper   = false
  numeric = false
  special = false
}

resource "random_string" "unique_id" {
  length  = 4
  lower   = true
  upper   = false
  numeric = false
  special = false
}

// ec2:CreateFleet only allows up to 4 InstanceRequirements overrides so we can only ever request
// a fleet across 4 or fewer subnets if we want to bid with InstanceRequirements instead of
// weighted instance types.
resource "random_shuffle" "subnets" {
  input        = data.aws_subnets.vpc.ids
  result_count = 4
}

locals {
  spot_allocation_strategy      = "lowestPrice"
  on_demand_allocation_strategy = "lowestPrice"
  instances                     = toset([for idx in range(var.instance_count) : tostring(idx)])
  cluster_name                  = coalesce(var.cluster_name, random_string.random_cluster_name.result)
  name_prefix                   = "${var.project_name}-${local.cluster_name}-${random_string.unique_id.result}"
  fleet_tag                     = "${local.name_prefix}-spot-fleet-target"
  fleet_tags = {
    Name                     = "${local.name_prefix}-${var.cluster_tag_key}-target"
    "${var.cluster_tag_key}" = local.cluster_name
    Fleet                    = local.fleet_tag
  }
}

resource "aws_iam_role" "target" {
  name               = "${local.name_prefix}-target-role"
  assume_role_policy = data.aws_iam_policy_document.target_role.json
}

resource "aws_iam_instance_profile" "target" {
  name = "${local.name_prefix}-target-profile"
  role = aws_iam_role.target.name
}

resource "aws_iam_role_policy" "target" {
  name   = "${local.name_prefix}-target-policy"
  role   = aws_iam_role.target.id
  policy = data.aws_iam_policy_document.target.json
}

resource "aws_security_group" "target" {
  name        = "${local.name_prefix}-target"
  description = "Target instance security group"
  vpc_id      = var.vpc_id

  # SSH traffic
  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
    ])
  }

  # Vault traffic
  ingress {
    from_port = 8200
    to_port   = 8201
    protocol  = "tcp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
      formatlist("%s/32", var.ssh_allow_ips)
    ])
  }

  # Consul traffic
  ingress {
    from_port = 8300
    to_port   = 8302
    protocol  = "tcp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
    ])
  }

  ingress {
    from_port = 8301
    to_port   = 8302
    protocol  = "udp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
    ])
  }

  ingress {
    from_port = 8500
    to_port   = 8503
    protocol  = "tcp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
    ])
  }

  ingress {
    from_port = 8600
    to_port   = 8600
    protocol  = "tcp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
    ])
  }

  ingress {
    from_port = 8600
    to_port   = 8600
    protocol  = "udp"
    cidr_blocks = flatten([
      formatlist("%s/32", data.enos_environment.localhost.public_ipv4_addresses),
      join(",", data.aws_vpc.vpc.cidr_block_associations.*.cidr_block),
    ])
  }

  # Internal traffic
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # External traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.common_tags,
    {
      Name = "${local.name_prefix}-sg"
    },
  )
}

resource "aws_launch_template" "target" {
  name     = "${local.name_prefix}-target"
  image_id = var.ami_id
  key_name = var.ssh_keypair

  iam_instance_profile {
    name = aws_iam_instance_profile.target.name
  }

  instance_requirements {
    burstable_performance = "included"

    memory_mib {
      min = var.instance_mem_min
      max = var.instance_mem_max
    }

    vcpu_count {
      min = var.instance_cpu_min
      max = var.instance_cpu_max
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.target.id]
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      var.common_tags,
      local.fleet_tags,
    )
  }
}

# There are three primary knobs we can turn to try and optimize our costs by
# using a spot fleet: our min and max instance requirements, our max bid
# price, and the allocation strategy to use when fulfilling the spot request.
# We've currently configured our instance requirements to allow for anywhere
# from 2-4 vCPUs and 4-16GB of RAM. We intentionally have a wide range
# to allow for a large instance size pool to be considered. Our next knob is our
# max bid price. As we're using spot fleets to save on instance cost, we never
# want to pay more for an instance than we were on-demand. We've set the max price
# to equal what we pay for t3.medium instances on-demand, which are the smallest
# reliable size for Vault scenarios. The final knob is the allocation strategy
# that AWS will use when looking for instances that meet our resource and cost
# requirements. We're using the "lowestPrice" strategy to get the absolute
# cheapest machines that will fit the requirements, but it comes with a slightly
# higher capacity risk than say, "capacityOptimized" or "priceCapacityOptimized".
# Unless we see capacity issues or instances being shut down then we ought to
# stick with that strategy.
resource "aws_ec2_fleet" "targets" {
  replace_unhealthy_instances         = false
  terminate_instances                 = true // terminate instances when we "delete" the fleet
  terminate_instances_with_expiration = false
  tags = merge(
    var.common_tags,
    local.fleet_tags,
  )
  type = "instant" // make a synchronous request for the entire fleet

  launch_template_config {
    launch_template_specification {
      launch_template_id = aws_launch_template.target.id
      version            = aws_launch_template.target.latest_version
    }

    dynamic "override" {
      for_each = random_shuffle.subnets.result

      content {
        subnet_id = override.value
      }
    }
  }

  on_demand_options {
    allocation_strategy = local.on_demand_allocation_strategy
    max_total_price     = (var.max_price * var.instance_count)
    min_target_capacity = var.capacity_type == "on-demand" ? var.instance_count : null
    // One of these has to be set to enforce our on-demand target capacity minimum
    single_availability_zone = false
    single_instance_type     = true
  }

  spot_options {
    allocation_strategy = local.spot_allocation_strategy
    // The instance_pools_to_use_count is only valid for the allocation_strategy
    // lowestPrice. When we are using that strategy we'll want to always set it
    // to non-zero to avoid rebuilding the fleet on a re-run. For any other strategy
    // set it to zero to avoid rebuilding the fleet on a re-run.
    instance_pools_to_use_count = local.spot_allocation_strategy == "lowestPrice" ? 1 : null
  }

  // Try and provision only spot instances and fall back to on-demand.
  target_capacity_specification {
    default_target_capacity_type = var.capacity_type
    spot_target_capacity         = var.capacity_type == "spot" ? var.instance_count : 0
    on_demand_target_capacity    = var.capacity_type == "on-demand" ? var.instance_count : 0
    target_capacity_unit_type    = "units" // units == instance count
    total_target_capacity        = var.instance_count
  }
}

data "aws_instance" "targets" {
  depends_on = [
    aws_ec2_fleet.targets,
  ]
  for_each = local.instances

  instance_id = aws_ec2_fleet.targets.fleet_instance_set[0].instance_ids[each.key]
}
