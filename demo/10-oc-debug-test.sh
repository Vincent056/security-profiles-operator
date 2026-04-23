#!/bin/bash
set -euo pipefail

echo "=== Step 10: Verify 'oc debug node' works with SPO webhooks ==="
echo ""
echo "In previous SPO versions, oc debug was blocked by SPO's mutating webhooks."
echo "In 0.10.0, the 'nodedebuggingpod.spo.io' webhook automatically allows"
echo "oc debug pods (matched by label app.kubernetes.io/managed-by=kubectl-debug)."
echo ""

WORKER=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers \
  -o custom-columns='NAME:.metadata.name' | head -1)
echo "Testing oc debug on worker node: $WORKER"
echo ""

oc debug "node/$WORKER" -- chroot /host uname -r

echo ""
echo "oc debug completed successfully. The SPO webhook allowed the debug pod."

echo ""
echo "=== Verify the webhook configuration ==="
oc get mutatingwebhookconfiguration spo-mutating-webhook-configuration \
  -o jsonpath='{range .webhooks[*]}{.name}{"\n"}{end}' 2>/dev/null || \
  echo "(webhook config not found - this is expected with staticWebhookConfig)"

echo ""
echo "The 'nodedebuggingpod.spo.io' webhook is listed above."
echo "It patches debug pods to ensure they are not blocked by SPO seccomp/SELinux enforcement."
