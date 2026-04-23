#!/bin/bash
set -euo pipefail

echo "=== Step 12: Test oc exec audit logging with Request UID correlation ==="
echo ""
echo "The execmetadata.spo.io webhook injects SPO_EXEC_REQUEST_UID into every"
echo "oc exec / kubectl exec command. This UID correlates the container audit"
echo "log with the Kubernetes API server audit log for the same exec request."
echo ""

echo "=== Creating test pod ==="
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: demo-exec-target
  namespace: spo-demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: Localhost
      localhostProfile: operator/demo-log-all.json
  containers:
  - name: app
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "infinity"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
EOF

echo "Waiting for pod..."
oc wait --for=condition=Ready pod/demo-exec-target -n spo-demo --timeout=30s
echo ""

echo "=== Running oc exec commands ==="
oc exec demo-exec-target -n spo-demo -- ls /etc/hostname
oc exec demo-exec-target -n spo-demo -- id
oc exec demo-exec-target -n spo-demo -- cat /etc/os-release | head -2
echo ""

INTERVAL=$(oc get spod spod -n openshift-security-profiles \
  -o jsonpath='{.spec.jsonEnricherOptions.auditLogIntervalSeconds}' 2>/dev/null)
INTERVAL=${INTERVAL:-60}
WAIT=$((INTERVAL + 5))
echo "=== Waiting ${WAIT}s for audit interval (${INTERVAL}s) to flush ==="
sleep "$WAIT"

POD_NODE=$(oc get pod demo-exec-target -n spo-demo -o jsonpath='{.spec.nodeName}')
SPOD_POD=$(oc get pods -n openshift-security-profiles -l name=spod \
  -o jsonpath="{.items[?(@.spec.nodeName=='$POD_NODE')].metadata.name}")
echo ""
echo "Target node: $POD_NODE"
echo "Spod pod:    $SPOD_POD"
echo ""

echo "=== JSON enricher entries for demo-exec-target ==="
echo ""
oc exec "$SPOD_POD" -n openshift-security-profiles -c json-enricher \
  -- tail -50 /data/logs/jsonenricher/audit.json 2>/dev/null \
  | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        res = d.get('resource') or {}
        if res.get('pod') != 'demo-exec-target': continue
        cmd = d.get('cmdLine','').strip()
        # Extract SPO_EXEC_REQUEST_UID from the command line
        uid = ''
        if 'SPO_EXEC_REQUEST_UID=' in cmd:
            uid = cmd.split('SPO_EXEC_REQUEST_UID=')[1].split(' ')[0]
            cmd_short = cmd.split('SPO_EXEC_REQUEST_UID=')[1].split(' ', 1)[1] if ' ' in cmd.split('SPO_EXEC_REQUEST_UID=')[1] else cmd
        else:
            cmd_short = cmd
        print(f'  Command:    {cmd_short}')
        print(f'  Request UID: {uid if uid else \"(none - not an exec)\"}')
        print(f'  Audit ID:   {d[\"auditID\"]}')
        print(f'  Syscalls:   {len(d.get(\"syscalls\",[]))} unique')
        print(f'  Timestamp:  {d[\"timestamp\"]}')
        print()
    except: pass
"

echo "=== How Request UID correlation works ==="
echo ""
echo "1. User runs:  oc exec demo-exec-target -- ls /etc/hostname"
echo "2. API server logs the exec request with a requestID in its audit log"
echo "3. SPO webhook (execmetadata.spo.io) injects SPO_EXEC_REQUEST_UID=<requestID>"
echo "   as an env var prefix to the exec command"
echo "4. JSON enricher captures the command line including the UID"
echo "5. You can now correlate: API server audit log <-> container syscall audit"
echo ""
echo "This closes the gap between 'who ran exec' and 'what syscalls were made'."
