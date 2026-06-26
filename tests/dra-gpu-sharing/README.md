# DRA GPU Sharing Test: 2 Pods + 2 VMs

Validates that DRA can simultaneously serve Intel GPU VFs to both pods (xe/DRM)
and VMs (VFIO passthrough via KubeVirt `GPUsWithDRA` feature gate).

**Target cluster:** snoials3 (OCP 4.22, single node, Intel Arc Pro B70 BMG-G31)

**Prerequisites:** `configure-cluster.yml` fully applied (DRA driver, CNV, NFD, LVMS).

## Test Ladder

Run each step sequentially. Only proceed after the current step passes.

### Step 1: Single pod with DRA GPU VF

```bash
oc apply -f 01-pod-single-vf.yml
oc wait pod/dra-pod-test -n default --for=condition=Ready --timeout=120s
oc logs dra-pod-test -n default
```

**Pass:** Pod Running, `/dev/dri/renderD*` visible, `sycl-ls` detects Intel GPU.

### Step 2: Two pods with DRA GPU VFs

```bash
oc apply -f 02-pods-two-vfs.yml
oc wait pod/dra-pod-test-2 -n default --for=condition=Ready --timeout=120s
oc logs dra-pod-test-2 -n default
```

**Pass:** Both pods Running, each sees one renderD device, PCI addresses differ.

### Step 3: VM with DRA GPU VF (VFIO passthrough)

```bash
oc apply -f 03-vm-single-vf.yml
oc wait vm/dra-vm-test -n default --for=condition=Ready --timeout=300s
virtctl ssh fedora@dra-vm-test -- lspci | grep -i display
virtctl ssh fedora@dra-vm-test -- dmesg | grep xe
```

**Pass:** VM boots, `lspci` shows Intel GPU, `dmesg` shows xe driver loading.

**Debugging if this fails:**
- DRA driver logs: `oc logs -n intel-gpu-resource-driver ds/intel-gpu-resource-driver-kubelet-plugin`
- VMI events: `oc describe vmi dra-vm-test -n default`
- Virt-launcher logs: `oc logs -n default $(oc get pod -n default -l kubevirt.io/domain=dra-vm-test -o name)`
- KEP-5304 metadata: exec into virt-launcher, check `/var/run/kubernetes.io/dra-device-attributes/`
- Host VFIO binding: `ssh core@<node> 'dmesg | grep vfio'`

### Step 4: Two VMs with DRA GPU VFs

```bash
oc apply -f 04-vms-two-vfs.yml
oc wait vm/dra-vm-test-2 -n default --for=condition=Ready --timeout=300s
virtctl ssh fedora@dra-vm-test-2 -- lspci | grep -i display
```

**Pass:** Both VMs running, each shows a GPU via `lspci`, device IDs differ.

### Step 5: Full validation (2 pods + 2 VMs = 4 VFs)

```bash
./05-validate.sh
```

**Pass:** All checks green — 4 claims, 4 unique VFs, no PF/iGPU allocation.

## Cleanup

```bash
./cleanup.sh
```
