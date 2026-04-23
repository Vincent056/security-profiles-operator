#!/bin/bash
set -euo pipefail

echo "=== Step 9: Verify JSON Log Enricher Output ==="
echo ""

POD_NODE=$(oc get pod demo-audit-workload -n spo-demo -o jsonpath='{.spec.nodeName}')
echo "Workload pod is on node: $POD_NODE"

SPOD_POD=$(oc get pods -n openshift-security-profiles -l name=spod \
  -o jsonpath="{.items[?(@.spec.nodeName=='$POD_NODE')].metadata.name}")
echo "Matching spod pod:       $SPOD_POD"
echo ""

echo "=== Check audit.json file on disk ==="
oc exec "$SPOD_POD" -n openshift-security-profiles -c json-enricher \
  -- ls -la /data/logs/jsonenricher/
echo ""

echo "=== Last 3 lines of audit.json ==="
oc exec "$SPOD_POD" -n openshift-security-profiles -c json-enricher \
  -- tail -3 /data/logs/jsonenricher/audit.json
echo ""

echo "=== Formatted sample (last line, pretty-printed) ==="
echo ""
oc exec "$SPOD_POD" -n openshift-security-profiles -c json-enricher \
  -- tail -1 /data/logs/jsonenricher/audit.json \
  | python3 -m json.tool 2>/dev/null || echo "(install python3 for pretty-print)"

echo ""
echo "=== Key fields in each JSON audit line ==="
echo "  auditID   - Unique ID for correlation with K8s API server audit logs"
echo "  cmdLine   - Command line of the process"
echo "  executable - Binary path"
echo "  resource  - Container name, pod name, namespace (K8s metadata)"
echo "  syscalls  - List of syscalls observed during the interval"
echo "  timestamp - When the audit entry was captured"
echo "  node      - Node where the event occurred"
echo "  uid/gid   - Process user/group IDs"
echo "  version   - Enricher output format version (spo/v1_alpha)"

echo ""
echo "=== JSON enricher options explained ==="
echo "  auditLogIntervalSeconds: Grouping interval (default 60s, we use 10s)"
echo "  auditLogPath:            File path under the mounted volume"
echo "                           Must be under /data/logs/jsonenricher/ (ConfigMap default)"
echo "  auditLogMaxSize:         Max file size in MB before rotation"
echo "  auditLogMaxBackups:      Number of rotated files to keep"
echo "  auditLogMaxAge:          Max days to keep rotated files"
echo ""
echo "  The volume mount path and source are defined in ConfigMap:"
echo "  'security-profiles-operator-profile' (keys: json-enricher-log-volume-*)"
echo "  You can patch the ConfigMap to change the volume type (e.g. hostPath)"
echo "  or mount path before enabling the enricher."
