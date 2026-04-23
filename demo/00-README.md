# Security Profiles Operator 0.10.0 - Enablement Demo

**Cluster**: OCP 4.21 nightly on AWS (RHCOS 9.6, kernel 5.14)
**SPO Version**: 0.10.0 (installed via OLM)
**Namespace**: `openshift-security-profiles` (operator), `spo-demo` (workloads)

## Demo Steps (run in order)

| Step | File | Description |
|------|------|-------------|
| 1 | `01-setup-namespace.sh` | Create the demo namespace |
| 2 | `02-spod-enable-selinux.yaml` | Enable SELinux support in SPOD |
| 3 | `03-seccomp-profile.yaml` | Create a SeccompProfile that logs all syscalls |
| 4 | `04-seccomp-pod.yaml` | Run a pod using the SeccompProfile |
| 5 | `05-selinux-profile.yaml` | Create a SelinuxProfile for var_log_t access |
| 6 | `06-selinux-pod.yaml` | Run a pod using the SELinux profile |
| 7 | `10-oc-debug-test.sh` | Verify oc debug works through SPO webhooks |
| 8 | `07-spod-enable-json-enricher.yaml` | Enable the JSON Log Enricher in SPOD |
| 9 | `08-json-enricher-workload.yaml` | Deploy a workload to generate audit events |
| 10 | `09-verify-json-enricher.sh` | Verify JSON enricher output |
| 11 | `12-exec-audit-test.sh` | Test oc exec audit logging with Request UID correlation |
| 12 | `11-spod-enable-log-enricher.yaml` | (Optional) Enable the classic auditd-based log enricher |
| 13 | `99-cleanup.sh` | Remove all demo resources |

**Important**: Create SELinux profiles (steps 5-6) and test `oc debug` (step 7)
BEFORE enabling the JSON enricher (step 8). The enricher's BPF hooks add a
container to the spod DaemonSet and trigger a rollout; creating profiles during
or just after the rollout can cause transient errors.

## Known Limitations on This Cluster

- **BPF recorder** (`enableBpfRecorder`) fails with `Permission denied` on
  `sys_exit_clone` tracepoint attachment. The BPF LSM on RHCOS 9.6 restricts
  `BPF_LINK_CREATE` for this tracepoint even in privileged containers. The
  tracepoint exists (id=124) and BTF is available, but the BPF LSM policy
  blocks it. The JSON enricher and log enricher use different BPF hooks that
  are not restricted.
- **`auditLogPath`** must be under the volume mount path defined in the ConfigMap
  `security-profiles-operator-profile` (key: `json-enricher-log-volume-mount-path`).
  The default mount path is `/data/logs/jsonenricher` backed by an `emptyDir`.
  You can patch the ConfigMap to change both the mount path and the volume
  source (e.g. `hostPath`, `persistentVolumeClaim`) before enabling the enricher.
- After toggling multiple SPOD features rapidly, the operator may get stuck in
  UPDATING state. If this happens, delete the SPOD CR and recreate it cleanly.
- SELinux profile installation can fail if the spod DaemonSet is still rolling
  out (finalizer `-deleted` issue). Wait for SPOD state=RUNNING before creating
  SELinux profiles.

## New 0.10.0 Features Demonstrated

1. **JSON Log Enricher** (step 8-10): eBPF-based audit logging in JSON lines
   format with per-process syscall grouping, auditID, and K8s resource correlation
2. **oc debug node support** (step 7): SPO webhooks now auto-allow `oc debug`
   pods via the `nodedebuggingpod.spo.io` webhook
3. **SELinux policy reload via Jobs** (automatic): SELinux profiles are installed
   via privileged Kubernetes Jobs (visible in step 5-6)
4. **SeccompProfile** (step 3-4): Basic seccomp profile lifecycle
5. **Log enricher** (step 11): Classic auditd-based per-syscall enrichment with
   K8s metadata (contrast with JSON enricher's grouped output)

## Test Results (OCP 4.21 / SPO 0.10.0)

| Feature | Status | Notes |
|---------|--------|-------|
| SeccompProfile create + pod | PASS | Profile installs on all nodes in ~5s |
| SELinux profile create + pod | PASS | Profile installs via privileged Jobs on all nodes |
| JSON enricher (stdout mode) | PASS | Rich JSON output with auditID, syscalls, K8s metadata |
| JSON enricher (`auditLogPath`) | PASS | Path must be under `/data/logs/jsonenricher/` (ConfigMap volume mount) |
| oc debug node | PASS | Webhook allows debug pods automatically |
| BPF recorder | FAIL | `sys_exit_clone` tracepoint permission denied on this cluster |
| Log enricher (auditd source) | PASS | Per-syscall audit lines with K8s metadata from auditd |
