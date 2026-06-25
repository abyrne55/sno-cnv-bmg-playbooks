# SNO + CNV + BMG GPU Ansible Playbooks

Ansible automation for provisioning a Single Node OpenShift (SNO) cluster with OpenShift Virtualization (CNV), LVMS storage, cert-manager TLS, and Intel BattleMage GPU passthrough.

Four playbooks cover the full lifecycle:

1. **`configure-cloudflare-dns.yml`** (Pre-deploy) — creates Cloudflare DNS records for the cluster
2. **`generate-iso.yml`** (Day-0) — generates an agent-based installer ISO with MachineConfigs baked in
3. **`configure-cluster.yml`** (Day-2) — installs operators, configures GPU passthrough, provisions a VM
4. **`teardown-cluster.yml`** (Teardown) — removes selected day-2 components, returning the cluster to a baseline

## Prerequisites

### Beaker Machine

Reserve a bare-metal machine via Beaker. Note its hostname, MAC address, NIC name, and IP address.

### DNS Records

DNS records (`<cluster>.<domain>`, `api.<cluster>.<domain>`, `api-int.<cluster>.<domain>`, `*.apps.<cluster>.<domain>`) are created automatically by `configure-cloudflare-dns.yml`. You need a Cloudflare API token with `Zone:DNS:Edit` permissions — set it in `vars/vault.yml` as `vault_cloudflare_api_token`.

### Tools

Install on workstation:

- `ansible` (with `kubernetes` and `dnspython` Python packages)
- `oc`
- `butane`
- `openshift-install`
- `helm` (only for DRA GPU mode)

## Quick Start

```bash
# 1. Install Ansible collections
ansible-galaxy collection install -r requirements.yml

# 2. Copy and edit variable files
cp vars/cluster.yml.example vars/cluster.yml
cp vars/vault.yml.example vars/vault.yml
# Edit vars/cluster.yml with your network, host, and GPU details
$EDITOR vars/cluster.yml

# 3. Encrypt and populate vault secrets
ansible-vault encrypt vars/vault.yml
ansible-vault edit vars/vault.yml

# 4. Create DNS records
ansible-playbook configure-cloudflare-dns.yml --ask-vault-pass

# 5. Generate ISO (day-0)
ansible-playbook generate-iso.yml --ask-vault-pass

# 6. Boot ISO on the target machine (manual: kexec or USB)

# 7. Configure cluster (day-2)
ansible-playbook configure-cluster.yml --ask-vault-pass
```

### Teardown

Remove day-2 components from the cluster (keeps LVMS, cert-manager, SR-IOV, and day-0 MachineConfigs):

```bash
# Full teardown: remove all teardown-managed components
ansible-playbook teardown-cluster.yml --ask-vault-pass

# Selective: remove only CNV
ansible-playbook teardown-cluster.yml --ask-vault-pass --tags cnv

# Dry run: preview changes without applying
ansible-playbook teardown-cluster.yml --check --diff --ask-vault-pass
```

To remove DNS records when decommissioning a cluster:

```bash
ansible-playbook configure-cloudflare-dns.yml --ask-vault-pass -e dns_state=absent
```

## Dry Run

Preview what the playbooks will do without making changes:

```bash
# Pre-deploy: shows planned DNS changes without creating records
ansible-playbook configure-cloudflare-dns.yml --check --diff --ask-vault-pass

# Day-0: shows template diffs, skips butane/openshift-install commands
ansible-playbook generate-iso.yml --check --diff --ask-vault-pass

# Day-2: renders day-2 YAMLs, shows k8s module diffs but skips resource creation
ansible-playbook configure-cluster.yml --check --diff --ask-vault-pass

# Teardown: shows what would be removed without deleting anything
ansible-playbook teardown-cluster.yml --check --diff --ask-vault-pass
```

## Variables

### Cluster Variables (`vars/cluster.yml`)

Copy `vars/cluster.yml.example` to `vars/cluster.yml` and edit. Variables at the top of the file are site-specific and must be changed; variables under "Defaults" are usually fine as-is.

### Vault Variables (`vars/vault.yml`)

Copy `vars/vault.yml.example` to `vars/vault.yml`, populate, and encrypt with `ansible-vault`.

| Variable | Description |
|----------|-------------|
| `vault_pull_secret` | Red Hat registry pull secret (JSON string) |
| `vault_cloudflare_api_token` | Cloudflare API token (Zone:DNS:Edit) |

## Tags

### `configure-cluster.yml`

| Tag | Roles | Description |
|-----|-------|-------------|
| `wait` | `wait_cluster` | Wait for cluster API + node ready |
| `vfio` | `vfio_gpu` | Apply VFIO MachineConfig (triggers reboot) |
| `lvms` | `lvms` | Install LVMS operator + LVMCluster |
| `cnv` | `cnv` | Install CNV operator + HyperConverged |
| `certmanager` | `certmanager` | Install cert-manager + Let's Encrypt TLS |
| `dra` | `dra_gpu` | Install Intel DRA GPU driver (Helm) |
| `vm` | `bmg_vm` | Create RHEL 10 BMG GPU VM |
| `verify` | `verify` | Print cluster/operator/cert/VM status |

### `teardown-cluster.yml`

| Tag | Description |
|-----|-------------|
| `smollm` | Remove smollm inference pods, ResourceClaimTemplates, ResourceClaims |
| `gpu` | Uninstall Intel GPU Base Operator (Helm releases, CRDs, RBAC, namespace) |
| `cnv` | Remove CNV operator, HyperConverged CR, CRDs, webhooks, namespace |
| `gpu-mc` | Delete SR-IOV + IOMMU MachineConfigs (triggers node reboot) |
| `assisted` | Delete assisted-installer namespace |

```bash
# Run specific tags
ansible-playbook configure-cluster.yml --ask-vault-pass --tags cnv,vm

# Skip tags
ansible-playbook configure-cluster.yml --ask-vault-pass --skip-tags certmanager
```

## Customizing for a Different Cluster

Override variables via `-e` flags:

```bash
ansible-playbook generate-iso.yml --ask-vault-pass \
  -e cluster_name=sno2 \
  -e rendezvous_ip=192.168.1.101 \
  -e mac_address=aa:bb:cc:dd:ee:ff \
  -e nic_name=eno1
```

Or create an alternate vars file and pass it with `--extra-vars @vars/sno2.yml`.

## GPU Access Modes

| Mode | Day-2 Roles | GPU Exposed As |
|------|-------------|----------------|
| `vfio` (default) | `wait_cluster` `vfio_gpu` `lvms` `cnv` `certmanager` `bmg_vm` `verify` | `devices.kubevirt.io/bmg-g31` (KubeVirt device plugin) |
| `dra` | `wait_cluster` `lvms` `certmanager` `dra_gpu` `verify` | `ResourceSlice` (DRA ResourceClaim) |

Modes are mutually exclusive; `wait_cluster`, `lvms`, `certmanager`, and `verify` run in both. Set `gpu_access_mode` to switch.

## Booting the ISO via kexec

On machines without BMC virtual media (or when virtual media is unavailable), use `kexec` to boot the agent ISO directly from a running RHEL system. This replaces the running kernel in-place — no BIOS interaction needed.

### Transfer the ISO

```bash
scp build/<cluster>/agent.x86_64.iso root@<host-ip>:/root/
```

### Extract boot files and build combined initrd

```bash
ssh root@<host-ip>

mkdir -p /mnt/iso
mount -o loop /root/agent.x86_64.iso /mnt/iso

cp /mnt/iso/images/pxeboot/vmlinuz /root/agent-vmlinuz
cp /mnt/iso/images/pxeboot/initrd.img /root/agent-initrd.img
cp /mnt/iso/images/ignition.img /root/agent-ignition.img
cp /mnt/iso/images/pxeboot/rootfs.img /root/agent-rootfs.img

umount /mnt/iso

cat /root/agent-initrd.img \
    /root/agent-ignition.img \
    /root/agent-rootfs.img \
    > /root/agent-combined-initrd.img
```

### Load and execute kexec

```bash
kexec -l /root/agent-vmlinuz \
  --initrd=/root/agent-combined-initrd.img \
  --append="rd.neednet=1 ignition.firstboot ignition.platform.id=metal console=tty0"

# Point of no return — RHEL is replaced immediately
sync && kexec -e
```

Adjust `console=` to match the machine's serial port if needed (e.g., `console=ttyS0,115200n8 console=tty0`). The machine needs at least 4 GB free RAM beyond what the OS uses to hold the ~1.3 GB combined initrd.

### Monitor the install

```bash
# From your workstation
openshift-install --dir build/<cluster> agent wait-for bootstrap-complete --log-level=info
openshift-install --dir build/<cluster> agent wait-for install-complete --log-level=info
```

### Important notes

- **Do not** include `coreos.liveiso=` or `coreos.live.rootfs_url=` in the kernel args — these cause hangs when booting via kexec with a combined initrd
- **`ignition.firstboot` and `ignition.platform.id=metal`** are required — without them, the Ignition config is silently skipped
- Generate the ISO on your **workstation**, not the target host — `openshift-install` creates `auth/kubeconfig` alongside the ISO, and the target disk will be wiped
- **Unbind VFIO devices before `kexec -e`** — if a PCI device is bound to `vfio-pci` (e.g. for GPU passthrough), the kexec transition will hang. Stop any VMs using the device, then unbind it: `echo <pci-addr> > /sys/bus/pci/drivers/vfio-pci/unbind`

## Known Issues

1. **Butane/Ignition version mismatch**: OCP 4.22 MCC only supports Ignition 3.5.0, but Butane with `version: 4.22.0` emits Ignition 3.6.0. Use `butane_ocp_version: 4.21.0`.

2. **openshift-install consumes configs**: `agent create image` deletes `install-config.yaml` and `agent-config.yaml`. The playbook backs them up and restores after.

3. **kubeconfig CA after TLS swap**: After patching APIServer with Let's Encrypt cert, the kubeconfig's `certificate-authority-data` (self-signed CA) causes TLS errors. The playbook strips it so `oc` uses the system trust store.

4. **LVMS channel naming**: LVMS uses version-specific channels (`stable-4.21`), not plain `stable`.
