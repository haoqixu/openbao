# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

scenario "seal_ha" {
  matrix {
    arch            = ["amd64", "arm64"]
    artifact_source = ["local", "crt", "artifactory"]
    artifact_type   = ["bundle", "package"]
    backend         = ["consul", "raft"]
    consul_version  = ["1.12.9", "1.13.9", "1.14.9", "1.15.5", "1.16.1"]
    distro          = ["ubuntu", "rhel"]
    edition         = ["ent", "ent.fips1402", "ent.hsm", "ent.hsm.fips1402"]
    primary_seal    = ["awskms"]
    secondary_seal  = ["awskms"]

    # Our local builder always creates bundles
    exclude {
      artifact_source = ["local"]
      artifact_type   = ["package"]
    }

    # HSM and FIPS 140-2 are only supported on amd64
    exclude {
      arch    = ["arm64"]
      edition = ["ent.fips1402", "ent.hsm", "ent.hsm.fips1402"]
    }
  }

  terraform_cli = terraform_cli.default
  terraform     = terraform.default
  providers = [
    provider.aws.default,
    provider.enos.ubuntu,
    provider.enos.rhel
  ]

  locals {
    artifact_path = matrix.artifact_source != "artifactory" ? abspath(var.vault_artifact_path) : null
    enos_provider = {
      rhel   = provider.enos.rhel
      ubuntu = provider.enos.ubuntu
    }
    manage_service    = matrix.artifact_type == "bundle"
    vault_install_dir = matrix.artifact_type == "bundle" ? var.vault_install_dir : global.vault_install_dir_packages[matrix.distro]
  }

  step "get_local_metadata" {
    skip_step = matrix.artifact_source != "local"
    module    = module.get_local_metadata
  }

  step "build_vault" {
    module = "build_${matrix.artifact_source}"

    variables {
      build_tags           = var.vault_local_build_tags != null ? var.vault_local_build_tags : global.build_tags[matrix.edition]
      artifact_path        = local.artifact_path
      goarch               = matrix.arch
      goos                 = "linux"
      artifactory_host     = matrix.artifact_source == "artifactory" ? var.artifactory_host : null
      artifactory_repo     = matrix.artifact_source == "artifactory" ? var.artifactory_repo : null
      artifactory_username = matrix.artifact_source == "artifactory" ? var.artifactory_username : null
      artifactory_token    = matrix.artifact_source == "artifactory" ? var.artifactory_token : null
      arch                 = matrix.artifact_source == "artifactory" ? matrix.arch : null
      product_version      = var.vault_product_version
      artifact_type        = matrix.artifact_type
      distro               = matrix.artifact_source == "artifactory" ? matrix.distro : null
      edition              = matrix.artifact_source == "artifactory" ? matrix.edition : null
      revision             = var.vault_revision
    }
  }

  step "ec2_info" {
    module = module.ec2_info
  }

  step "create_vpc" {
    module = module.create_vpc

    variables {
      common_tags = global.tags
    }
  }

  step "create_primary_seal_key" {
    module = "seal_key_${matrix.primary_seal}"

    variables {
      cluster_id   = step.create_vpc.cluster_id
      cluster_meta = "primary"
      common_tags  = global.tags
    }
  }

  step "create_secondary_seal_key" {
    module = "seal_key_${matrix.secondary_seal}"

    variables {
      cluster_id      = step.create_vpc.cluster_id
      cluster_meta    = "secondary"
      common_tags     = global.tags
      other_resources = step.create_primary_seal_key.resource_names
    }
  }

  // This step reads the contents of the backend license if we're using a Consul backend and
  // the edition is "ent".
  step "read_backend_license" {
    skip_step = matrix.backend == "raft" || var.backend_edition == "ce"
    module    = module.read_license

    variables {
      file_name = global.backend_license_path
    }
  }

  step "read_vault_license" {
    skip_step = matrix.edition == "ce"
    module    = module.read_license

    variables {
      file_name = global.vault_license_path
    }
  }

  step "create_vault_cluster_targets" {
    module     = module.target_ec2_instances
    depends_on = [step.create_vpc]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      ami_id          = step.ec2_info.ami_ids[matrix.arch][matrix.distro][global.distro_version[matrix.distro]]
      cluster_tag_key = global.vault_tag_key
      common_tags     = global.tags
      seal_key_names  = step.create_secondary_seal_key.resource_names
      vpc_id          = step.create_vpc.id
    }
  }

  step "create_vault_cluster_backend_targets" {
    module     = matrix.backend == "consul" ? module.target_ec2_instances : module.target_ec2_shim
    depends_on = [step.create_vpc]

    providers = {
      enos = provider.enos.ubuntu
    }

    variables {
      ami_id          = step.ec2_info.ami_ids["arm64"]["ubuntu"]["22.04"]
      seal_key_names  = step.create_secondary_seal_key.resource_names
      cluster_tag_key = global.backend_tag_key
      common_tags     = global.tags
      vpc_id          = step.create_vpc.id
    }
  }

  step "create_backend_cluster" {
    module = "backend_${matrix.backend}"
    depends_on = [
      step.create_vault_cluster_backend_targets
    ]

    providers = {
      enos = provider.enos.ubuntu
    }

    variables {
      cluster_name    = step.create_vault_cluster_backend_targets.cluster_name
      cluster_tag_key = global.backend_tag_key
      license         = (matrix.backend == "consul" && var.backend_edition == "ent") ? step.read_backend_license.license : null
      release = {
        edition = var.backend_edition
        version = matrix.consul_version
      }
      target_hosts = step.create_vault_cluster_backend_targets.hosts
    }
  }

  step "create_vault_cluster" {
    module = module.vault_cluster
    depends_on = [
      step.create_backend_cluster,
      step.build_vault,
      step.create_vault_cluster_targets
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      artifactory_release     = matrix.artifact_source == "artifactory" ? step.build_vault.vault_artifactory_release : null
      backend_cluster_name    = step.create_vault_cluster_backend_targets.cluster_name
      backend_cluster_tag_key = global.backend_tag_key
      cluster_name            = step.create_vault_cluster_targets.cluster_name
      consul_license          = (matrix.backend == "consul" && var.backend_edition == "ent") ? step.read_backend_license.license : null
      consul_release = matrix.backend == "consul" ? {
        edition = var.backend_edition
        version = matrix.consul_version
      } : null
      enable_audit_devices = var.vault_enable_audit_devices
      install_dir          = local.vault_install_dir
      license              = matrix.edition != "ce" ? step.read_vault_license.license : null
      local_artifact_path  = local.artifact_path
      manage_service       = local.manage_service
      packages             = concat(global.packages, global.distro_packages[matrix.distro])
      // Only configure our primary seal during our initial cluster setup
      seal_type       = matrix.primary_seal
      seal_key_name   = step.create_primary_seal_key.resource_name
      storage_backend = matrix.backend
      target_hosts    = step.create_vault_cluster_targets.hosts
    }
  }

  // Wait for our cluster to elect a leader
  step "wait_for_leader" {
    module     = module.vault_wait_for_leader
    depends_on = [step.create_vault_cluster]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      timeout           = 120 # seconds
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  step "get_vault_cluster_ips" {
    module     = module.vault_get_cluster_ips
    depends_on = [step.wait_for_leader]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  step "verify_vault_unsealed" {
    module     = module.vault_verify_unsealed
    depends_on = [step.wait_for_leader]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_install_dir = local.vault_install_dir
      vault_instances   = step.create_vault_cluster_targets.hosts
    }
  }

  // Write some test data before we create the new seal
  step "verify_write_test_data" {
    module = module.vault_verify_write_data
    depends_on = [
      step.create_vault_cluster,
      step.get_vault_cluster_ips,
      step.verify_vault_unsealed,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      leader_public_ip  = step.get_vault_cluster_ips.leader_public_ip
      leader_private_ip = step.get_vault_cluster_ips.leader_private_ip
      vault_instances   = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  // Wait for the initial seal rewrap to complete before we add our HA seal.
  step "wait_for_initial_seal_rewrap" {
    module = module.vault_wait_for_seal_rewrap
    depends_on = [
      step.verify_write_test_data,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  // Stop the vault service on all nodes before we restart with new seal config
  step "stop_vault" {
    module = module.stop_vault
    depends_on = [
      step.create_vault_cluster,
      step.verify_write_test_data,
      step.wait_for_initial_seal_rewrap,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      target_hosts = step.create_vault_cluster_targets.hosts
    }
  }

  // Add the secondary seal to the cluster
  step "add_ha_seal_to_cluster" {
    module     = module.start_vault
    depends_on = [step.stop_vault]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      cluster_name            = step.create_vault_cluster_targets.cluster_name
      install_dir             = local.vault_install_dir
      license                 = matrix.edition != "ce" ? step.read_vault_license.license : null
      manage_service          = local.manage_service
      seal_type               = matrix.primary_seal
      seal_key_name           = step.create_primary_seal_key.resource_name
      seal_type_secondary     = matrix.secondary_seal
      seal_key_name_secondary = step.create_secondary_seal_key.resource_name
      storage_backend         = matrix.backend
      target_hosts            = step.create_vault_cluster_targets.hosts
    }
  }

  // Wait for our cluster to elect a leader
  step "wait_for_new_leader" {
    module     = module.vault_wait_for_leader
    depends_on = [step.add_ha_seal_to_cluster]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      timeout           = 120 # seconds
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  step "get_updated_cluster_ips" {
    module     = module.vault_get_cluster_ips
    depends_on = [step.wait_for_new_leader]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  step "verify_vault_unsealed_with_new_seal" {
    module     = module.vault_verify_unsealed
    depends_on = [step.wait_for_new_leader]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_install_dir = local.vault_install_dir
      vault_instances   = step.create_vault_cluster_targets.hosts
    }
  }

  // Wait for the seal rewrap to complete and verify that no entries failed
  step "wait_for_seal_rewrap" {
    module = module.vault_wait_for_seal_rewrap
    depends_on = [
      step.add_ha_seal_to_cluster,
      step.verify_vault_unsealed_with_new_seal,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  // Perform all of our standard verifications after we've enabled multiseal
  step "verify_vault_version" {
    module     = module.vault_verify_version
    depends_on = [step.wait_for_seal_rewrap]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances       = step.create_vault_cluster_targets.hosts
      vault_edition         = matrix.edition
      vault_install_dir     = local.vault_install_dir
      vault_product_version = matrix.artifact_source == "local" ? step.get_local_metadata.version : var.vault_product_version
      vault_revision        = matrix.artifact_source == "local" ? step.get_local_metadata.revision : var.vault_revision
      vault_build_date      = matrix.artifact_source == "local" ? step.get_local_metadata.build_date : var.vault_build_date
      vault_root_token      = step.create_vault_cluster.root_token
    }
  }

  step "verify_raft_auto_join_voter" {
    skip_step  = matrix.backend != "raft"
    module     = module.vault_verify_raft_auto_join_voter
    depends_on = [step.wait_for_seal_rewrap]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_install_dir = local.vault_install_dir
      vault_instances   = step.create_vault_cluster_targets.hosts
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  step "verify_replication" {
    module     = module.vault_verify_replication
    depends_on = [step.wait_for_seal_rewrap]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_edition     = matrix.edition
      vault_install_dir = local.vault_install_dir
      vault_instances   = step.create_vault_cluster_targets.hosts
    }
  }

  // Make sure our data is still available
  step "verify_read_test_data" {
    module     = module.vault_verify_read_data
    depends_on = [step.wait_for_seal_rewrap]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      node_public_ips   = step.get_updated_cluster_ips.follower_public_ips
      vault_install_dir = local.vault_install_dir
    }
  }

  step "verify_ui" {
    module     = module.vault_verify_ui
    depends_on = [step.wait_for_seal_rewrap]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_instances = step.create_vault_cluster_targets.hosts
    }
  }

  // Make sure we have a "multiseal" seal type
  step "verify_seal_type" {
    // Don't run this on versions less than 1.16.0-beta1 until VAULT-21053 is fixed on prior branches.
    skip_step  = semverconstraint(var.vault_product_version, "< 1.16.0-beta1")
    module     = module.verify_seal_type
    depends_on = [step.wait_for_seal_rewrap]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_install_dir = local.vault_install_dir
      vault_hosts       = step.create_vault_cluster_targets.hosts
      seal_type         = "multiseal"
    }
  }

  // Now we'll migrate away from our initial seal to our secondary seal

  // Stop the vault service on all nodes before we restart with new seal config
  step "stop_vault_for_migration" {
    module = module.stop_vault
    depends_on = [
      step.wait_for_seal_rewrap,
      step.verify_read_test_data,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      target_hosts = step.create_vault_cluster_targets.hosts
    }
  }

  // Remove the "primary" seal from the cluster. Set our "secondary" seal to priority 1. We do this
  // by restarting vault with the correct config.
  step "remove_primary_seal" {
    module     = module.start_vault
    depends_on = [step.stop_vault_for_migration]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      cluster_name    = step.create_vault_cluster_targets.cluster_name
      install_dir     = local.vault_install_dir
      license         = matrix.edition != "ce" ? step.read_vault_license.license : null
      manage_service  = local.manage_service
      seal_alias      = "secondary"
      seal_type       = matrix.secondary_seal
      seal_key_name   = step.create_secondary_seal_key.resource_name
      storage_backend = matrix.backend
      target_hosts    = step.create_vault_cluster_targets.hosts
    }
  }

  // Wait for our cluster to elect a leader after restarting vault with a new primary seal
  step "wait_for_leader_after_migration" {
    module     = module.vault_wait_for_leader
    depends_on = [step.remove_primary_seal]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      timeout           = 120 # seconds
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  // Since we've restarted our cluster we might have a new leader and followers. Get the new IPs.
  step "get_cluster_ips_after_migration" {
    module     = module.vault_get_cluster_ips
    depends_on = [step.wait_for_leader_after_migration]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  // Make sure we unsealed
  step "verify_vault_unsealed_after_migration" {
    module     = module.vault_verify_unsealed
    depends_on = [step.wait_for_leader_after_migration]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_install_dir = local.vault_install_dir
      vault_instances   = step.create_vault_cluster_targets.hosts
    }
  }

  // Wait for the seal rewrap to complete and verify that no entries failed
  step "wait_for_seal_rewrap_after_migration" {
    module = module.vault_wait_for_seal_rewrap
    depends_on = [
      step.wait_for_leader_after_migration,
      step.verify_vault_unsealed_after_migration,
    ]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_hosts       = step.create_vault_cluster_targets.hosts
      vault_install_dir = local.vault_install_dir
      vault_root_token  = step.create_vault_cluster.root_token
    }
  }

  // Make sure our data is still available after migration
  step "verify_read_test_data_after_migration" {
    module     = module.vault_verify_read_data
    depends_on = [step.wait_for_seal_rewrap_after_migration]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      node_public_ips   = step.get_cluster_ips_after_migration.follower_public_ips
      vault_install_dir = local.vault_install_dir
    }
  }

  // Make sure we have our secondary seal type after migration
  step "verify_seal_type_after_migration" {
    // Don't run this on versions less than 1.16.0-beta1 until VAULT-21053 is fixed on prior branches.
    skip_step  = semverconstraint(var.vault_product_version, "<= 1.16.0-beta1")
    module     = module.verify_seal_type
    depends_on = [step.wait_for_seal_rewrap_after_migration]

    providers = {
      enos = local.enos_provider[matrix.distro]
    }

    variables {
      vault_install_dir = local.vault_install_dir
      vault_hosts       = step.create_vault_cluster_targets.hosts
      seal_type         = matrix.secondary_seal
    }
  }

  output "audit_device_file_path" {
    description = "The file path for the file audit device, if enabled"
    value       = step.create_vault_cluster.audit_device_file_path
  }

  output "cluster_name" {
    description = "The Vault cluster name"
    value       = step.create_vault_cluster.cluster_name
  }

  output "hosts" {
    description = "The Vault cluster target hosts"
    value       = step.create_vault_cluster.target_hosts
  }

  output "primary_seal_key_name" {
    description = "The Vault cluster primary seal key name"
    value       = step.create_primary_seal_key.resource_name
  }

  output "private_ips" {
    description = "The Vault cluster private IPs"
    value       = step.create_vault_cluster.private_ips
  }

  output "public_ips" {
    description = "The Vault cluster public IPs"
    value       = step.create_vault_cluster.public_ips
  }

  output "root_token" {
    description = "The Vault cluster root token"
    value       = step.create_vault_cluster.root_token
  }

  output "recovery_key_shares" {
    description = "The Vault cluster recovery key shares"
    value       = step.create_vault_cluster.recovery_key_shares
  }

  output "recovery_keys_b64" {
    description = "The Vault cluster recovery keys b64"
    value       = step.create_vault_cluster.recovery_keys_b64
  }

  output "recovery_keys_hex" {
    description = "The Vault cluster recovery keys hex"
    value       = step.create_vault_cluster.recovery_keys_hex
  }

  output "secondary_seal_key_name" {
    description = "The Vault cluster secondary seal key name"
    value       = step.create_secondary_seal_key.resource_name
  }

  output "unseal_keys_b64" {
    description = "The Vault cluster unseal keys"
    value       = step.create_vault_cluster.unseal_keys_b64
  }

  output "unseal_keys_hex" {
    description = "The Vault cluster unseal keys hex"
    value       = step.create_vault_cluster.unseal_keys_hex
  }
}
