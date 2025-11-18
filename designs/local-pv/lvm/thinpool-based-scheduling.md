---
oep-number: OEP 4084
title: OpenEBS Enhancement Proposal for ThinPool based Scheduling
authors:
  - "@abhilashshetty04"
owners:
  - "@abhilashshetty04"
editor: TBD
creation-date: 2025-10-10
last-updated: 2025-11-04
status: implemented
---

# OpenEBS Enhancement Proposal for ThinPool based Scheduling

## Table of Contents

1. [Overview](#overview)
2. [Abbreviations](#abbreviations)
3. [Motivation](#motivation)
4. [Goals](#goals)
5. [Non-Goals](#non-goals)
6. [Proposal](#proposal)
7. [User Stories](#user-stories)
8. [Implementation Details](#implementation-details)
9. [Testing](#testing)

---

## Overview

This proposal introduces ThinPool in VolumeGroup object. VolumeGroups ([]VolumeGroup) is part of lvmnode crd definition. This will be used for making scheduling decision of thin PVC.

## Abbreviations

- PVC: Pversistent Volume Claim
- LV: Logical Volume
- VG: Volume Group
- PE: Physical Extent
- CR: Custom Resource
- CRD: Custom Resource Definition

## Motivation

- LocalPV LVM creates a thinpool LV (thick from the VG allocation perspective) on the VG to hold thin LVs. When a thin LV is scheduled on a VG, if the VG does not already have a thinpool LV, it is created by the node plugin before creating the thin LV.
- With capacity monitoring enabled, the thinpool is extended as more PE is allocated to LVs. We don’t downsize the thinpool when a thin LV is removed — it’s destroyed only when the last thin LV is deleted.
- OpenEBS takes care of thinpool lifecycle. However, We have seen users creating a thinpool spanning the VG size beforehand. In this scenario the whole VG is configured to schedule thin LVs. Without having thinpool LV stats scheduler might not know if thin LV can be accommodated by the VG it shows no free space.
- We have received several user issues.
  - [lvm-localpv/issues/382](https://github.com/openebs/lvm-localpv/issues/382)
  - [lvm-localpv/issues/356](https://github.com/openebs/lvm-localpv/issues/356)
- We schedule thick lv on a node without checking if there are VG which can accommodate it.

## Goals

- Add thinpool LV in the VolumeGroup struct of lvmnode CR.
- Update the LVMNode’s []ThinPool field when a VG includes a thin pool.
- Evaluate thinpool and VG capacity before scheduling thin LV.
- Use PVC size for scheduling decisions. It’s currently not factored in.

## Non-Goals

- Resizing down thinpool on each thin LV destroy.
- Overprovision limit on VG for thin lv.

## Proposal

1. **Add Thinpool in VolumeGroup object**
  - lvmnode CR has []VolumeGroup. We will add optional []ThinPool on VolumeGroup struct.

2. **Update thinpool information**:
  - lvmnode controller periodically updates VG state of lvmnode CR. []ThinPool will also be updated in the same step.

3. **Changes in scheduler algorithm**:
  - In SpaceWeighted, Include thinpool free space for thin volumes while finding VG with max free space on the Node.
  - For thick volume, Scheduler will check if the VG has enough space to host the LV on all algorithm.
  We will fail the scheduling if it doesn't have enough space on VG.
  - Changes CapacityWeighted and VolumeWeighted to use nodelist rather then volumelist as with this we just
  ignore VG which does not have any volumes on them. By using nodes, we ensure all VGs are considered.

## User Stories

1. **Story 1**:
  As a System Administrator, I want thin pvc to get scheduled optimally. I want scheduler to use thinpool and VG capacity to to select VG for lvmvolume CR.

## Implementation Details

### Design

- **LVMNode CRD change**:

  ```
  type LVMNode struct {
    metav1.TypeMeta   `json:",inline"`
    metav1.ObjectMeta `json:"metadata,omitempty"`
    VolumeGroups []VolumeGroup `json:"volumeGroups"`
  }
  ```

  Adding a new field here. Its optional, So won't be a breaking change during upgrade from older to this CRD.

  ```
  type VolumeGroup struct {
    ...
    // ThinPools hosted by the volume group.
    ThinPools []ThinPool `json:"thinPools,omitempty"`
  }
  ```

  ```
  type ThinPool struct {
    // Name of the thinpool lv.
    // +kubebuilder:validation:Required
    Name string `json:"name"`
    // Size of the thinpool lv, in bytes.
    // +kubebuilder:validation:Required
    Size resource.Quantity `json:"size"`
    // Free capacity of thinpool, in bytes.
    // +kubebuilder:validation:Required
    Free resource.Quantity `json:"free"`
  }
  ```

- **Changes in Scheduler**:

  - For thin PVC:
    - In SpaceWeighted, Include thinpool free space for thin volumes while finding VG with max free space on the Node.
    - We might have to limit overprovisioning somehow. Not doing that here.
  - For thick PVC:
    - Scheduler will check if the VG has enough space to host the LV on all algorithm.

### Components to Update

- **LvmNode CRD**: Add []thinpool in VolumeGroup.
- **Node agent**: Add logic to fetch and update thinpools for a VolumeGroup.
- **Controller**: Modify scheduler to use thinpool spec while scheduling thin PVC.
- **OpenEBS Plugin**: Add thinpool details in volume-groups response.

## Testing

- Validate thinpools getting populated
- Ensure thin volume scheduling accounts for thinpool usage
