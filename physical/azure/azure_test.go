// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: MPL-2.0

package azure

import (
	"context"
	"fmt"
	"net"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/openbao/openbao/helper/testhelpers/azurite"

	"github.com/Azure/azure-storage-blob-go/azblob"
	log "github.com/hashicorp/go-hclog"
	"github.com/openbao/openbao/sdk/helper/logging"
	"github.com/openbao/openbao/sdk/physical"
)

/// These tests run against an Azurite docker container, unless AZURE_ACCOUNT_NAME is given.
/// Authentication options:
/// - Use a static access key via AZURE_ACCOUNT_KEY
/// - Use managed identities (leave AZURE_ACCOUNT_KEY empty)
///
/// To run the tests using managed identities, the following pre-requisites have to be met:
/// 1. Access to the Azure Instance Metadata Service (IMDS) is required (e.g. run it on a Azure VM)
/// 2. A system-assigned oder user-assigned identity attached to the host running the test
/// 3. A role assignment for a storage account with "Storage Blob Data Contributor" permissions

func testFixture(t *testing.T) (*AzureBackend, func()) {
	t.Helper()

	ts := time.Now().UnixNano()
	name := fmt.Sprintf("vault-test-%d", ts)
	_ = os.Setenv("AZURE_BLOB_CONTAINER", name)

	cleanup := func() {}
	backendConf := map[string]string{
		"container": name,
	}

	if os.Getenv("AZURE_ACCOUNT_NAME") == "" {
		dockerCleanup, conf := azurite.PrepareTestContainer(t, "")
		cfgaz := conf.(*azurite.Config)
		backendConf["accountName"] = cfgaz.AccountName
		backendConf["accountKey"] = cfgaz.AccountKey
		backendConf["testHost"] = cfgaz.Endpoint
		cleanup = dockerCleanup
	} else {
		accountKey := os.Getenv("AZURE_ACCOUNT_KEY")
		if accountKey != "" {
			t.Log("using account key provided to authenticate against storage account")
		} else {
			t.Log("using managed identity to authenticate against storage account")
			if !isIMDSReachable(t) {
				t.Log("running managed identity test requires access to the Azure IMDS with a valid identity for a storage account attached to it, skipping")
				t.SkipNow()
			}
		}
	}

	backend, err := NewAzureBackend(backendConf, logging.NewVaultLogger(log.Debug))
	if err != nil {
		defer cleanup()
		t.Fatalf("err: %s", err)
	}

	azBackend := backend.(*AzureBackend)

	return azBackend, func() {
		blobService, err := azBackend.container.GetProperties(context.Background(), azblob.LeaseAccessConditions{})
		if err != nil {
			t.Logf("failed to retrieve blob container info: %v", err)
			return
		}

		if blobService.StatusCode() == 200 {
			_, err := azBackend.container.Delete(context.Background(), azblob.ContainerAccessConditions{})
			if err != nil {
				t.Logf("clean up failed: %v", err)
			}
		}
		cleanup()
	}
}

func TestAzureBackend(t *testing.T) {
	backend, cleanup := testFixture(t)
	defer cleanup()

	physical.ExerciseBackend(t, backend)
	physical.ExerciseBackend_ListPrefix(t, backend)
}

func TestAzureBackend_ListPaging(t *testing.T) {
	backend, cleanup := testFixture(t)
	defer cleanup()

	// by default, azure returns 5000 results in a page, load up more than that
	for i := 0; i < MaxListResults+100; i++ {
		if err := backend.Put(context.Background(), &physical.Entry{
			Key:   "foo" + strconv.Itoa(i),
			Value: []byte(strconv.Itoa(i)),
		}); err != nil {
			t.Fatalf("err: %s", err)
		}
	}

	results, err := backend.List(context.Background(), "")
	if err != nil {
		t.Fatalf("err: %s", err)
	}

	if len(results) != MaxListResults+100 {
		t.Fatalf("expected %d, got %d, %v", MaxListResults+100, len(results), results)
	}
}

func isIMDSReachable(t *testing.T) bool {
	t.Helper()

	_, err := net.DialTimeout("tcp", "169.254.169.254:80", time.Second*3)
	if err != nil {
		return false
	}

	return true
}
