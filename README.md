# SNO + CNV + BMG GPU Ansible Playbooks

Ansible automation for provisioning a Single Node OpenShift (SNO) cluster with OpenShift Virtualization (CNV), LVMS storage, cert-manager TLS, and Intel BattleMage GPU passthrough.

Two playbooks cover the full lifecycle:

1. **`generate-iso.yml`** (Day-0) — generates an agent-based installer ISO with MachineConfigs baked in
2. **`configure-cluster.yml`** (Day-2) — installs operators, configures GPU passthrough, provisions a VM

## Prerequisites

### Beaker Machine

Reserve a bare-metal machine via Beaker. Note its hostname, MAC address, NIC name, and IP address.

### DNS Records

Create these DNS records pointing to the machine's IP:

| Record | Type | Value |
|--------|------|-------|
| `api.<cluster>.<domain>` | A | machine IP |
| `api-int.<cluster>.<domain>` | A | machine IP |
| `*.apps.<cluster>.<domain>` | A | machine IP |

### Tools

Install on workstation:

- `ansible` (with `kubernetes` and `PyYAML` Python packages)
- `oc`
- `butane`
- `openshift-install`

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

# 4. Generate ISO (day-0)
ansible-playbook generate-iso.yml --ask-vault-pass

# 5. Boot ISO on the target machine (manual: kexec or USB)

# 6. Configure cluster (day-2)
ansible-playbook configure-cluster.yml --ask-vault-pass
```

## Dry Run

Preview what the playbooks will do without making changes:

```bash
# Day-0: renders templates, shows butane/openshift-install commands but skips them
ansible-playbook generate-iso.yml --check --diff --ask-vault-pass

# Day-2: renders day-2 YAMLs, shows k8s module diffs but skips resource creation
ansible-playbook configure-cluster.yml --check --diff --ask-vault-pass
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

| Tag | Roles | Description |
|-----|-------|-------------|
| `iso` | `generate_iso` | Generate agent-based installer ISO |
| `wait` | `wait_cluster` | Wait for cluster API + node ready |
| `vfio` | `vfio_gpu` | Apply VFIO MachineConfig (triggers reboot) |
| `lvms` | `lvms` | Install LVMS operator + LVMCluster |
| `cnv` | `cnv` | Install CNV operator + HyperConverged |
| `certmanager` | `certmanager` | Install cert-manager + Let's Encrypt TLS |
| `dra` | `dra_gpu` | Install Intel DRA GPU driver (Helm) |
| `vm` | `bmg_vm` | Create RHEL 10 BMG GPU VM |
| `verify` | `verify` | Print cluster/operator/cert/VM status |

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
| `vfio` (default) | `vfio_gpu` + `cnv` + `bmg_vm` | `devices.kubevirt.io/bmg-g31` (KubeVirt device plugin) |
| `dra` | `dra_gpu` | `ResourceSlice` (DRA ResourceClaim) |

Modes are mutually exclusive. Set `gpu_access_mode` to switch.

## Known Issues

1. **Butane/Ignition version mismatch**: OCP 4.22 MCC only supports Ignition 3.5.0, but Butane with `version: 4.22.0` emits Ignition 3.6.0. Use `butane_ocp_version: 4.21.0`.

2. **openshift-install consumes configs**: `agent create image` deletes `install-config.yaml` and `agent-config.yaml`. The playbook backs them up and restores after.

3. **kubeconfig CA after TLS swap**: After patching APIServer with Let's Encrypt cert, the kubeconfig's `certificate-authority-data` (self-signed CA) causes TLS errors. The playbook strips it so `oc` uses the system trust store.

4. **LVMS channel naming**: LVMS uses version-specific channels (`stable-4.21`), not plain `stable`.
