#!/usr/bin/env bash
# Validates Step 5: 2 pods + 2 VMs each with a distinct VF, no PF/iGPU allocation.
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Step 5 Validation: 2 Pods + 2 VMs with DRA GPU VFs ==="
echo

# --- Pods ---
echo "--- Pods ---"
for pod in dra-pod-test dra-pod-test-2; do
  phase=$(oc get pod "$pod" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
    pass "$pod phase=$phase"
  else
    fail "$pod phase=$phase (expected Running or Succeeded)"
  fi
done
echo

# --- VMs ---
echo "--- VMs ---"
for vm in dra-vm-test dra-vm-test-2; do
  ready=$(oc get vm "$vm" -n default -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
  if [[ "$ready" == "true" ]]; then
    pass "$vm ready=true"
  else
    fail "$vm ready=$ready (expected true)"
  fi
done
echo

# --- ResourceClaims ---
echo "--- ResourceClaims ---"
claims_json=$(oc get resourceclaim -n default -o json 2>/dev/null)
claim_count=$(echo "$claims_json" | jq '.items | length')

if [[ "$claim_count" -ge 4 ]]; then
  pass "$claim_count resource claims found (expected >= 4)"
else
  fail "$claim_count resource claims found (expected >= 4)"
fi

# Extract allocated device names from claims
allocated_devices=$(echo "$claims_json" | jq -r '
  .items[].status.allocation.devices.results[]?.device // empty
' | sort)
echo "  Allocated devices: $(echo "$allocated_devices" | tr '\n' ' ')"

unique_devices=$(echo "$allocated_devices" | sort -u | wc -l)
total_devices=$(echo "$allocated_devices" | wc -l)

if [[ "$unique_devices" -eq "$total_devices" && "$total_devices" -ge 4 ]]; then
  pass "No double-allocation ($unique_devices unique devices across $total_devices allocations)"
else
  fail "Possible double-allocation: $unique_devices unique out of $total_devices total"
fi
echo

# --- PF and iGPU exclusion ---
echo "--- PF/iGPU Exclusion ---"
pf_allocated=$(echo "$claims_json" | jq -r '
  [.items[].status.allocation.devices.results[]? |
   select(.device | startswith("0000-04-00-0"))] | length
')
igpu_allocated=$(echo "$claims_json" | jq -r '
  [.items[].status.allocation.devices.results[]? |
   select(.device | startswith("0000-00-02-0"))] | length
')

if [[ "$pf_allocated" -eq 0 ]]; then
  pass "PF (04:00.0) not allocated"
else
  fail "PF (04:00.0) is allocated ($pf_allocated claims)"
fi

if [[ "$igpu_allocated" -eq 0 ]]; then
  pass "iGPU (00:02.0) not allocated"
else
  fail "iGPU (00:02.0) is allocated ($igpu_allocated claims)"
fi
echo

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "OVERALL: FAIL"
  exit 1
else
  echo "OVERALL: PASS"
fi
