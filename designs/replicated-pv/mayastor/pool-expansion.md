---
oep-number: OEP 3904
title: OpenEBS Enhancement Proposal for Mayastor DiskPool Expansion
authors:
  - "@abhilashshetty04"
owners:
  - "@abhilashshetty04"
editor: TBD
creation-date: 2025-08-13
last-updated: 2025-09-03
status: implementable
---

# OpenEBS Enhancement Proposal for Mayastor DiskPool Expansion

## Table of Contents

1. [Overview](#overview)
2. [Motivation](#motivation)
3. [Goals](#goals)
4. [Non-Goals](#non-goals)
5. [Proposal](#proposal)
6. [User Stories](#user-stories)
7. [Implementation Details](#implementation-details)
8. [Testing](#testing)

---

## Overview

This proposal introduces the DiskPool Expansion feature to Mayastor pools of type **Lvs**, allowing users to increase pool capacity on the fly after expanding the underlying disk.

## Motivation

- Mayastor allows pool overcommitment via thin provisioning. In such cases, it is expected that as the allocation nears it's    capacity, the storage administrator will proactively expand it to avoid replicas reaching the ENOSPC (no space) state. Currently, Mayastor does not support pool expansion.

- Allows cluster to expand in Storage Capacity without adding new Pool or Node. It's an important utility for both on-premise or cloud based deployments if Pools are backed by storage disks which allows expansion.

- We have received several user requests to support Mayastor pool expansion. Example:
   [User Request](https://github.com/orgs/openebs/projects/78?pane=issue&itemId=92928609&issue=openebs%7Cmayastor%7C1631)

## Goals

- Allow user to expand the DiskPool upon expanding the backing disk.
- Pool should be expandable when there are active IO operations. Without needing maintenance window.

## Non-Goals

- This proposal does not implement backend disk expand capability. User will have to do that first before initiating mayastor DiskPool expand.
- This proposal does not implement Diskpool shrink.
- This proposal does not implement Expansion by adding additional Disk to the Pool.
- This proposal does not implement infinite Expansion capability. User has to define the expected expansion factor or expected expansion size limit at DiskPool creation time.

## Proposal

1. **New CLI command** in the OpenEBS plugin:

  kubectl openebs mayastor expand pool <pool-id>

2. **DSP operator-based trigger**:

  Adding annotation `"openebs.io/expand-pool": true` on DSP CR will trigger the expand api for the Pool.

3. **New field in Pool CR spec**:

  `maxExpansion` defines the maximum expected expansion.

  Users can specify it in two ways:
  - **Absolute size**:
    - For ex. 800GiB, 3.5TiB or 4563726394B. User will have to specify the unit. Otherwise we will fail the request as it creates ambiguity.
    - Our implementation uses binary storage units, so values are expected in MiB, GiB, or TiB rather than MB, GB, or TB.
  - **Factors**:
    - For ex. "1x", "20x", "8x" or "5x". 5x will allow the Pool to be grown 5 times of it's initial capacity.
  - These inputs gets converted into blobsore metadata reservation ratio. If not specified, we default it to 200. Which allows 2x growth from initial capacity.

4. A New Pool/DSP status field

  - `max_expandable_size`: This is the absolute maximum growable size. Even expansion of additional 1 cluster would fail. Please note that this would not impact any existing blobs or the volumes using those blobs for application IO. It's just that the extended backing disk capacity is unusable.

  - `disk_capacity` will show the size of the underlying disk.

  NOTE: `capacity` is the actual usable space of the Pool after reserving metadata from `disk_capacity`. So while growing user/admin should consider current `disk_capacity` and `max_expandable_size`

### Key Concepts

**LVS Metadata restriction**:
  When a mayastor pool is created, The metadata region is initialized which is immutable. Future expansion of the pool depends on the metadata reserved on create time. `maxExpansion` in the CR spec is used to reserve required metadata. All DiskPools created prior to this will have a limited expand capability as they would be not having enough metadata to accommodate bigger disk size. The User/Admin might need to manually move replica off of the Pool and recreate the Pool by using `maxExpansion` if they want to expand older Pools.


### Workflow

1. **Diskpool CRD migration**:
   - After the mayastor upgrade to release with this feature support. The existing CR will get a new field called `max_expandable_size` in their status. Newer pool creation can have `maxExpansion` field in the spec to allow future expansion.

2. **Diskpool Creation**:
    - The user/admin creates a diskpool yaml spec that contains the `maxExpansion` field indicating the expected expansion in factor or absolute size.
    - When the spec is applied, the diskpool operator picks up this request and dispatches the create pool request to the Mayastor agents that complete the diskpool provisioning.
    - The spec for creating a pool with `maxExpansion` can look like below:

      - **Using factor**
        ```
        apiVersion: "openebs.io/v1beta3"
        kind: DiskPool
        metadata:
          name: <pool-name>
          namespace: <namespace>
        spec:
          node: <node-name>
          disks: ["/dev/disk/by-id/<id>"]
          maxExpansion: "20x"
        ```

      - **Using absolute size**
        ```
        apiVersion: "openebs.io/v1beta3"
        kind: DiskPool
        metadata:
          name: <pool-name>
          namespace: <namespace>
        spec:
          node: <node-name>
          disks: ["/dev/disk/by-id/<id>"]
          maxExpansion: "6TiB"
        ```

   - The User/Admin can check `max_expandable_size` of the newly provisioned pool. It should be honoring the `maxExpansion`.

3. **Expansion the DiskPool**:
   - The User/Admin must expand the backing disk (≤ `max_expandable_size`).
   - Then User/Admin can do either of the following to trigger mayastor pool expand workflow:
     - **Annotate the DSP CR**
       - add annotation `"openebs.io/expand-pool": true` on the CR to trigger reconciliation loop. The Operator removes the annotation when the expand succeeds or it sees error
       which is deemed irrecoverable.
     - **Use openebs plugin**
       - Run kubectl openebs mayastor expand pool <pool-id> which will call expand pool api.


## User Stories

1. **Story 1**:
  As a System Administrator, I notice few Pool's Allocation is nearing Capacity. It has higher committed size then capacity. Hence, I want to expand the pool to avoid thin provisioned replicas encountering ENOSPC.

## Implementation Details

### Design

- **Pool Creation workflow**:
   - The user/admin creates a diskpool yaml spec that contains the `maxExpansion` field indicating the expected expansion.
   - As `maxExpansion` increases, depending on host performance we have noticed create pool takes more time due to higher number of metadata pages
   - Using larger `clusterSize` seems to reduce the time, As it reduces a number of metadata pages getting reserved, page can track more number of cluster too so `maxExpansion` is honoured.
   - DSP Operator calls a grow_pool api, Request is passed down to the Io-Engine container present on the node which creates the pool with required configuration.
   - Pool is created with enough metadata to expand the pool at least `maxExpansion` times it's initial capacity or at least upto `maxExpansion` if absolute size is passed.
   - Once a pool is created, it's `maxExpansion` cannot be modified, and the `max_expandable_size` remains fixed for the lifetime of the pool.

- **Pool Expansion workflow**:
  - When a User/Admin triggers expand pool request. In io-engine, the underlying aio bdev is scanned. If we don't see extended `disk_capacity` we will return `FailedPrecondition` error. Will remove annotation if triggered from DSP operator.
  - If metadata is exhausted because disk is grown beyond `max_expandable_size`, We will return ResourceExhausted. In this case also we will remove annotation if triggered from DSP Operator.
  - If node is not Online. DSP operator will keep retrying.

### Components to Update
- **openebs and mayastor plugin**: New subcommmand called expand.
- **DiskPool Custom Resource Definition**: The Custom Resource will have maxExpansion in spec and `max_expandable_size` in status.
- **Control-Plane agent-core**: New field will get added in PoolSpec for `maxExpansion`. No Spec updates during expand call.
- **Data-Plane io-engine**: io-engine need to `bdev_aio_rescan` and call `spdk_lvs_grow_live`.
- **SPDK**: Need a new function to get `max_expandable_size` of the blobstore.

## Testing
 - Expansion of pool with varying maxExpansion, clusterSize and disk size
 - Expansion of encrypted pool with varying maxExpansion, clusterSize and disk size
 - Expansion of pool with varying maxExpansion, clusterSize and disk size
 - Pool creation with invalid maxExpansion format
 - Pool expansion from plugin when the node is not online
 - Pool expansion from dsp Custom resource annotation when the node is not online
 - Pool expansion from dsp annotation when the underlying disk is not extended
 - Pool expansion from plugin when the underlying disk is not extended

