#!/bin/bash
set -euo pipefail

echo "=== Cleanup: Removing all demo resources ==="

echo "Deleting demo pods..."
oc delete pod demo-seccomp-pod demo-selinux-pod demo-audit-workload -n spo-demo \
  --grace-period=0 --force 2>/dev/null || true

echo "Deleting demo profiles..."
oc delete seccompprofile demo-log-all -n spo-demo 2>/dev/null || true
oc delete selinuxprofile demo-errorlogger -n spo-demo 2>/dev/null || true

echo "Deleting demo namespace..."
oc delete project spo-demo 2>/dev/null || true

echo ""
echo "=== Resetting SPOD to default config ==="
echo "(Disabling enrichers, keeping SELinux enabled)"
oc patch spod spod -n openshift-security-profiles --type=merge \
  -p '{"spec":{"enableJsonEnricher":false,"enableLogEnricher":false}}'

echo ""
echo "Waiting for SPOD to stabilize..."
sleep 10
oc get spod spod -n openshift-security-profiles -o wide

echo ""
echo "Cleanup complete."
