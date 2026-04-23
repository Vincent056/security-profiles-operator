#!/bin/bash
set -euo pipefail

echo "=== Step 1: Create demo namespace ==="
oc new-project spo-demo 2>/dev/null || oc project spo-demo

echo ""
echo "=== Verify SPO is installed and running ==="
oc get spod spod -n openshift-security-profiles -o wide
echo ""
oc get csv -n openshift-security-profiles | grep security-profiles
echo ""
echo "=== SPO pods ==="
oc get pods -n openshift-security-profiles
echo ""
echo "Done. Namespace 'spo-demo' is ready."
