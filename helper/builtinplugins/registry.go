// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package builtinplugins

import (
	"context"

	credAliCloud "github.com/hashicorp/vault-plugin-auth-alicloud"
	credAzure "github.com/hashicorp/vault-plugin-auth-azure"
	credCentrify "github.com/hashicorp/vault-plugin-auth-centrify"
	credCF "github.com/hashicorp/vault-plugin-auth-cf"
	credGcp "github.com/hashicorp/vault-plugin-auth-gcp/plugin"
	credJWT "github.com/hashicorp/vault-plugin-auth-jwt"
	credKerb "github.com/hashicorp/vault-plugin-auth-kerberos"
	credKube "github.com/hashicorp/vault-plugin-auth-kubernetes"
	credOCI "github.com/hashicorp/vault-plugin-auth-oci"
	dbCouchbase "github.com/hashicorp/vault-plugin-database-couchbase"
	dbElastic "github.com/hashicorp/vault-plugin-database-elasticsearch"
	dbMongoAtlas "github.com/hashicorp/vault-plugin-database-mongodbatlas"
	dbRedis "github.com/hashicorp/vault-plugin-database-redis"
	dbRedisElastiCache "github.com/hashicorp/vault-plugin-database-redis-elasticache"
	dbSnowflake "github.com/hashicorp/vault-plugin-database-snowflake"
	logicalAd "github.com/hashicorp/vault-plugin-secrets-ad/plugin"
	logicalAlicloud "github.com/hashicorp/vault-plugin-secrets-alicloud"
	logicalAzure "github.com/hashicorp/vault-plugin-secrets-azure"
	logicalGcp "github.com/hashicorp/vault-plugin-secrets-gcp/plugin"
	logicalGcpKms "github.com/hashicorp/vault-plugin-secrets-gcpkms"
	logicalKube "github.com/hashicorp/vault-plugin-secrets-kubernetes"
	logicalKv "github.com/hashicorp/vault-plugin-secrets-kv"
	logicalMongoAtlas "github.com/hashicorp/vault-plugin-secrets-mongodbatlas"
	logicalLDAP "github.com/hashicorp/vault-plugin-secrets-openldap"
	logicalTerraform "github.com/hashicorp/vault-plugin-secrets-terraform"
	credAppRole "github.com/openbao/openbao/builtin/credential/approle"
	credAws "github.com/openbao/openbao/builtin/credential/aws"
	credCert "github.com/openbao/openbao/builtin/credential/cert"
	credGitHub "github.com/openbao/openbao/builtin/credential/github"
	credLdap "github.com/openbao/openbao/builtin/credential/ldap"
	credOkta "github.com/openbao/openbao/builtin/credential/okta"
	credRadius "github.com/openbao/openbao/builtin/credential/radius"
	credUserpass "github.com/openbao/openbao/builtin/credential/userpass"
	logicalAws "github.com/openbao/openbao/builtin/logical/aws"
	logicalConsul "github.com/openbao/openbao/builtin/logical/consul"
	logicalNomad "github.com/openbao/openbao/builtin/logical/nomad"
	logicalPki "github.com/openbao/openbao/builtin/logical/pki"
	logicalRabbit "github.com/openbao/openbao/builtin/logical/rabbitmq"
	logicalSsh "github.com/openbao/openbao/builtin/logical/ssh"
	logicalTotp "github.com/openbao/openbao/builtin/logical/totp"
	logicalTransit "github.com/openbao/openbao/builtin/logical/transit"
	dbCass "github.com/openbao/openbao/plugins/database/cassandra"
	dbHana "github.com/openbao/openbao/plugins/database/hana"
	dbInflux "github.com/openbao/openbao/plugins/database/influxdb"
	dbMongo "github.com/openbao/openbao/plugins/database/mongodb"
	dbMssql "github.com/openbao/openbao/plugins/database/mssql"
	dbMysql "github.com/openbao/openbao/plugins/database/mysql"
	dbPostgres "github.com/openbao/openbao/plugins/database/postgresql"
	dbRedshift "github.com/openbao/openbao/plugins/database/redshift"
	"github.com/openbao/openbao/sdk/framework"
	"github.com/openbao/openbao/sdk/helper/consts"
	"github.com/openbao/openbao/sdk/logical"
)

// Registry is inherently thread-safe because it's immutable.
// Thus, rather than creating multiple instances of it, we only need one.
var Registry = newRegistry()

var addExternalPlugins = addExtPluginsImpl

// BuiltinFactory is the func signature that should be returned by
// the plugin's New() func.
type BuiltinFactory func() (interface{}, error)

// There are three forms of Backends which exist in the BuiltinRegistry.
type credentialBackend struct {
	logical.Factory
	consts.DeprecationStatus
}

type databasePlugin struct {
	Factory BuiltinFactory
	consts.DeprecationStatus
}

type logicalBackend struct {
	logical.Factory
	consts.DeprecationStatus
}

type removedBackend struct {
	*framework.Backend
}

func removedFactory(ctx context.Context, config *logical.BackendConfig) (logical.Backend, error) {
	removedBackend := &removedBackend{}
	removedBackend.Backend = &framework.Backend{}
	return removedBackend, nil
}

func newRegistry() *registry {
	reg := &registry{
		credentialBackends: map[string]credentialBackend{
			"alicloud": {Factory: credAliCloud.Factory},
			"app-id": {
				Factory:           removedFactory,
				DeprecationStatus: consts.Removed,
			},
			"approle":    {Factory: credAppRole.Factory},
			"aws":        {Factory: credAws.Factory},
			"azure":      {Factory: credAzure.Factory},
			"centrify":   {Factory: credCentrify.Factory},
			"cert":       {Factory: credCert.Factory},
			"cf":         {Factory: credCF.Factory},
			"gcp":        {Factory: credGcp.Factory},
			"github":     {Factory: credGitHub.Factory},
			"jwt":        {Factory: credJWT.Factory},
			"kerberos":   {Factory: credKerb.Factory},
			"kubernetes": {Factory: credKube.Factory},
			"ldap":       {Factory: credLdap.Factory},
			"oci":        {Factory: credOCI.Factory},
			"oidc":       {Factory: credJWT.Factory},
			"okta":       {Factory: credOkta.Factory},
			"pcf": {
				Factory:           credCF.Factory,
				DeprecationStatus: consts.Deprecated,
			},
			"radius":   {Factory: credRadius.Factory},
			"userpass": {Factory: credUserpass.Factory},
		},
		databasePlugins: map[string]databasePlugin{
			// These four plugins all use the same mysql implementation but with
			// different username settings passed by the constructor.
			"mysql-database-plugin":        {Factory: dbMysql.New(dbMysql.DefaultUserNameTemplate)},
			"mysql-aurora-database-plugin": {Factory: dbMysql.New(dbMysql.DefaultLegacyUserNameTemplate)},
			"mysql-rds-database-plugin":    {Factory: dbMysql.New(dbMysql.DefaultLegacyUserNameTemplate)},
			"mysql-legacy-database-plugin": {Factory: dbMysql.New(dbMysql.DefaultLegacyUserNameTemplate)},

			"cassandra-database-plugin":         {Factory: dbCass.New},
			"couchbase-database-plugin":         {Factory: dbCouchbase.New},
			"elasticsearch-database-plugin":     {Factory: dbElastic.New},
			"hana-database-plugin":              {Factory: dbHana.New},
			"influxdb-database-plugin":          {Factory: dbInflux.New},
			"mongodb-database-plugin":           {Factory: dbMongo.New},
			"mongodbatlas-database-plugin":      {Factory: dbMongoAtlas.New},
			"mssql-database-plugin":             {Factory: dbMssql.New},
			"postgresql-database-plugin":        {Factory: dbPostgres.New},
			"redshift-database-plugin":          {Factory: dbRedshift.New},
			"redis-database-plugin":             {Factory: dbRedis.New},
			"redis-elasticache-database-plugin": {Factory: dbRedisElastiCache.New},
			"snowflake-database-plugin":         {Factory: dbSnowflake.New},
		},
		logicalBackends: map[string]logicalBackend{
			"ad": {
				Factory:           logicalAd.Factory,
				DeprecationStatus: consts.Deprecated,
			},
			"alicloud": {Factory: logicalAlicloud.Factory},
			"aws":      {Factory: logicalAws.Factory},
			"azure":    {Factory: logicalAzure.Factory},
			"cassandra": {
				Factory:           removedFactory,
				DeprecationStatus: consts.Removed,
			},
			"consul":     {Factory: logicalConsul.Factory},
			"gcp":        {Factory: logicalGcp.Factory},
			"gcpkms":     {Factory: logicalGcpKms.Factory},
			"kubernetes": {Factory: logicalKube.Factory},
			"kv":         {Factory: logicalKv.Factory},
			"mongodb": {
				Factory:           removedFactory,
				DeprecationStatus: consts.Removed,
			},
			// The mongodbatlas secrets engine is not the same as the database plugin equivalent
			// (`mongodbatlas-database-plugin`), and thus will not be deprecated at this time.
			"mongodbatlas": {Factory: logicalMongoAtlas.Factory},
			"mssql": {
				Factory:           removedFactory,
				DeprecationStatus: consts.Removed,
			},
			"mysql": {
				Factory:           removedFactory,
				DeprecationStatus: consts.Removed,
			},
			"nomad":    {Factory: logicalNomad.Factory},
			"openldap": {Factory: logicalLDAP.Factory},
			"ldap":     {Factory: logicalLDAP.Factory},
			"pki":      {Factory: logicalPki.Factory},
			"postgresql": {
				Factory:           removedFactory,
				DeprecationStatus: consts.Removed,
			},
			"rabbitmq":  {Factory: logicalRabbit.Factory},
			"ssh":       {Factory: logicalSsh.Factory},
			"terraform": {Factory: logicalTerraform.Factory},
			"totp":      {Factory: logicalTotp.Factory},
			"transit":   {Factory: logicalTransit.Factory},
		},
	}

	addExternalPlugins(reg)

	return reg
}

func addExtPluginsImpl(r *registry) {}

type registry struct {
	credentialBackends map[string]credentialBackend
	databasePlugins    map[string]databasePlugin
	logicalBackends    map[string]logicalBackend
}

// Get returns the Factory func for a particular backend plugin from the
// plugins map.
func (r *registry) Get(name string, pluginType consts.PluginType) (func() (interface{}, error), bool) {
	switch pluginType {
	case consts.PluginTypeCredential:
		if f, ok := r.credentialBackends[name]; ok {
			return toFunc(f.Factory), ok
		}
	case consts.PluginTypeSecrets:
		if f, ok := r.logicalBackends[name]; ok {
			return toFunc(f.Factory), ok
		}
	case consts.PluginTypeDatabase:
		if f, ok := r.databasePlugins[name]; ok {
			return f.Factory, ok
		}
	default:
		return nil, false
	}

	return nil, false
}

// Keys returns the list of plugin names that are considered builtin plugins.
func (r *registry) Keys(pluginType consts.PluginType) []string {
	var keys []string
	switch pluginType {
	case consts.PluginTypeDatabase:
		for key, backend := range r.databasePlugins {
			keys = appendIfNotRemoved(keys, key, backend.DeprecationStatus)
		}
	case consts.PluginTypeCredential:
		for key, backend := range r.credentialBackends {
			keys = appendIfNotRemoved(keys, key, backend.DeprecationStatus)
		}
	case consts.PluginTypeSecrets:
		for key, backend := range r.logicalBackends {
			keys = appendIfNotRemoved(keys, key, backend.DeprecationStatus)
		}
	}
	return keys
}

func (r *registry) Contains(name string, pluginType consts.PluginType) bool {
	for _, key := range r.Keys(pluginType) {
		if key == name {
			return true
		}
	}
	return false
}

// DeprecationStatus returns the Deprecation status for a builtin with type `pluginType`
func (r *registry) DeprecationStatus(name string, pluginType consts.PluginType) (consts.DeprecationStatus, bool) {
	switch pluginType {
	case consts.PluginTypeCredential:
		if f, ok := r.credentialBackends[name]; ok {
			return f.DeprecationStatus, ok
		}
	case consts.PluginTypeSecrets:
		if f, ok := r.logicalBackends[name]; ok {
			return f.DeprecationStatus, ok
		}
	case consts.PluginTypeDatabase:
		if f, ok := r.databasePlugins[name]; ok {
			return f.DeprecationStatus, ok
		}
	default:
		return consts.Unknown, false
	}

	return consts.Unknown, false
}

func toFunc(ifc interface{}) func() (interface{}, error) {
	return func() (interface{}, error) {
		return ifc, nil
	}
}

func appendIfNotRemoved(keys []string, name string, status consts.DeprecationStatus) []string {
	if status != consts.Removed {
		return append(keys, name)
	}
	return keys
}
