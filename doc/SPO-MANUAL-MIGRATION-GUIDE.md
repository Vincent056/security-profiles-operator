# Security Profiles Operator Manual Migration Guide

This guide provides step-by-step instructions for manually migrating Security Profiles Operator (SPO) from namespace-scoped to cluster-scoped CRDs, based on real cluster examples.

## Current Setup Example

This guide uses the following real setup as an example:
- **Namespace**: `openshift-security-profiles`
- **Profiles**:
  - SeccompProfile: `profile-block-all`
  - SelinuxProfile: `errorlogger-selinuxd-test`
  - RawSelinuxProfile: `errorlogger`
- **Profile Bindings**:
  - `profile-binding-seccomp` (binds nginx:1.19.1 to seccomp profile)
  - `profile-binding-selinuxd` (binds to SELinux profile)
- **Test Pods** in `nginx-deploy` namespace:
  - `nginx-19-1` (uses SELinux profile)
  - `nginx-19-1-seccomp` (uses seccomp profile)

## Pre-Migration Checklist

- [ ] Cluster admin access verified: `oc whoami` should show admin user
- [ ] Required tools installed: `oc`, `jq`
- [ ] Maintenance window scheduled
- [ ] Users notified about migration
- [ ] Current profiles documented

## Step 1: Create Backup Directory

```bash
# Create backup directory with timestamp
export BACKUP_DIR="spo-manual-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p $BACKUP_DIR/{profiles,bindings-recordings,workload-analysis}

# Save cluster information
echo "Backup Date: $(date)" > $BACKUP_DIR/backup-info.txt
echo "Cluster: $(oc whoami --show-server)" >> $BACKUP_DIR/backup-info.txt
echo "User: $(oc whoami)" >> $BACKUP_DIR/backup-info.txt

echo "Created backup directory: $BACKUP_DIR"
```

**Actual output:**
```
Created backup directory: spo-manual-backup-20250729-203554
```

## Step 2: Identify Workloads Using SPO Profiles

### Check Seccomp Profile Usage
```bash
# Find pods using SPO seccomp profiles
oc get pods -A -o json | jq -r '
  .items[] | 
  select(
    (.spec.securityContext.seccompProfile.type == "Localhost" and 
     (.spec.securityContext.seccompProfile.localhostProfile | startswith("operator/"))) or
    (any(.spec.containers[]; 
        .securityContext.seccompProfile.type == "Localhost" and
        (.securityContext.seccompProfile.localhostProfile | startswith("operator/"))))
  ) | 
  "\(.metadata.namespace)/\(.metadata.name) - \(.spec.securityContext.seccompProfile.localhostProfile // (.spec.containers[].securityContext.seccompProfile.localhostProfile // "unknown"))"
' | tee $BACKUP_DIR/workload-analysis/seccomp-usage.txt
```

**Actual output:**
```
nginx-deploy/nginx-19-1-seccomp - operator/openshift-security-profiles/profile-block-all.json
```

### Check SELinux Profile Usage

First, get all SELinux profile usage patterns:
```bash
# Get all SELinux profile usage patterns
echo "=== SELinux Profiles ===" > $BACKUP_DIR/workload-analysis/selinux-profiles.txt
oc get selinuxprofiles -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.usage)"' >> $BACKUP_DIR/workload-analysis/selinux-profiles.txt

echo "=== Raw SELinux Profiles ===" >> $BACKUP_DIR/workload-analysis/selinux-profiles.txt
oc get rawselinuxprofiles -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.usage)"' >> $BACKUP_DIR/workload-analysis/selinux-profiles.txt

cat $BACKUP_DIR/workload-analysis/selinux-profiles.txt
```

**Actual output:**
```
=== SELinux Profiles ===
openshift-security-profiles/errorlogger-selinuxd-test: errorlogger-selinuxd-test_openshift-security-profiles.process
=== Raw SELinux Profiles ===
openshift-security-profiles/errorlogger: errorlogger_openshift-security-profiles.process
```

Then find pods using these SELinux profiles:
```bash
# Extract all SELinux usage patterns
SELINUX_TYPES=$(oc get selinuxprofiles,rawselinuxprofiles -A -o json | jq -r '.items[].status.usage' | sort -u)

# Find pods using any of these SELinux types
for selinux_type in $SELINUX_TYPES; do
  echo "Checking for pods using: $selinux_type" >> $BACKUP_DIR/workload-analysis/selinux-usage.txt
  oc get pods -A -o json | jq -r --arg type "$selinux_type" '
    .items[] | 
    select(
      (.spec.securityContext.seLinuxOptions.type == $type) or
      (any(.spec.containers[]; .securityContext.seLinuxOptions.type == $type))
    ) | 
    "\(.metadata.namespace)/\(.metadata.name) - \($type)"
  ' >> $BACKUP_DIR/workload-analysis/selinux-usage.txt
done

cat $BACKUP_DIR/workload-analysis/selinux-usage.txt
```

**Actual output:**
```
Checking for pods using: errorlogger-selinuxd-test_openshift-security-profiles.process
nginx-deploy/nginx-19-1 - errorlogger-selinuxd-test_openshift-security-profiles.process
Checking for pods using: errorlogger_openshift-security-profiles.process
```

### Alternative way to find workload profile usage for selinuxprofile and seccompprofile:

```bash
oc get selinuxprofiles -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.activeWorkloads)"'

oc get seccompprofiles -A -o json | jq -r '.items[] | "\(.metada
ta.namespace)/\(.metadata.name): \(.status.activeWorkloads)"'
```

### Verify SELinux Profile Usage Format
```bash
# Check the actual SELinux profile usage format
oc get selinuxprofiles -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.usage)"'
```

**Actual output:**
```
openshift-security-profiles/errorlogger-selinuxd-test: errorlogger-selinuxd-test_openshift-security-profiles.process
```

## Step 3: Backup SPO Objects

### Backup SPO Daemon Configuration (Optional)
```bash
# Check if custom spod configuration exists
oc get spod -A
```

**Actual output:**
```
NAMESPACE                     NAME   STATE
openshift-security-profiles   spod   RUNNING
```

```bash
# Backup spod configuration if you have made any custom changes
oc get spod spod -n openshift-security-profiles -o json | jq '.' > \
  "$BACKUP_DIR/spod-configuration.json"
echo "Backed up spod configuration"

# Check for any custom settings
echo "Current spod custom settings:"
oc get spod spod -n openshift-security-profiles -o json | jq '.spec'
```

### Backup Profile Bindings
```bash
# Backup all profile bindings from all namespaces
for ns in $(oc get profilebindings -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "Checking namespace: $ns for profile bindings"
  for binding in $(oc get profilebindings -n $ns -o name); do
    name=$(echo $binding | cut -d'/' -f2)
    oc get profilebinding $name -n $ns -o json | jq '.' > \
      "$BACKUP_DIR/bindings-recordings/profilebindings-${ns}-${name}.json"
    echo "Backed up profilebinding: $name from namespace: $ns"
  done
done
```

**Actual output:**
```
Checking namespace: openshift-security-profiles for profile bindings
Backed up profilebinding: profile-binding-seccomp from namespace: openshift-security-profiles
Backed up profilebinding: profile-binding-selinuxd from namespace: openshift-security-profiles
```

### Backup Security Profiles
```bash
# Backup seccomp profiles from all namespaces
for ns in $(oc get seccompprofiles -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "Checking namespace: $ns for seccomp profiles"
  for profile in $(oc get seccompprofiles -n $ns -o name); do
    name=$(echo $profile | cut -d'/' -f2)
    oc get seccompprofile $name -n $ns -o json | jq '.' > \
      "$BACKUP_DIR/profiles/seccompprofiles-${ns}-${name}.json"
    echo "Backed up seccompprofile: $name from namespace: $ns"
  done
done

# Backup SELinux profiles from all namespaces
for ns in $(oc get selinuxprofiles -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "Checking namespace: $ns for SELinux profiles"
  for profile in $(oc get selinuxprofiles -n $ns -o name); do
    name=$(echo $profile | cut -d'/' -f2)
    oc get selinuxprofile $name -n $ns -o json | jq '.' > \
      "$BACKUP_DIR/profiles/selinuxprofiles-${ns}-${name}.json"
    echo "Backed up selinuxprofile: $name from namespace: $ns"
  done
done

# Backup raw SELinux profiles from all namespaces
for ns in $(oc get rawselinuxprofiles -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "Checking namespace: $ns for raw SELinux profiles"
  for profile in $(oc get rawselinuxprofiles -n $ns -o name); do
    name=$(echo $profile | cut -d'/' -f2)
    oc get rawselinuxprofile $name -n $ns -o json | jq '.' > \
      "$BACKUP_DIR/profiles/rawselinuxprofiles-${ns}-${name}.json"
    echo "Backed up rawselinuxprofile: $name from namespace: $ns"
  done
done
```

**Actual output:**
```
Checking namespace: openshift-security-profiles for seccomp profiles
Backed up seccompprofile: profile-block-all from namespace: openshift-security-profiles
Checking namespace: openshift-security-profiles for SELinux profiles
Backed up selinuxprofile: errorlogger-selinuxd-test from namespace: openshift-security-profiles
Checking namespace: openshift-security-profiles for raw SELinux profiles
Backed up rawselinuxprofile: errorlogger from namespace: openshift-security-profiles
```

### Create Backup Summary
```bash
echo "=== Backup Summary ===" > $BACKUP_DIR/backup-summary.txt
echo "Total files backed up: $(find $BACKUP_DIR -name "*.json" | wc -l)" >> $BACKUP_DIR/backup-summary.txt
echo "" >> $BACKUP_DIR/backup-summary.txt
echo "SPOD configuration: $([ -f $BACKUP_DIR/spod-configuration.json ] && echo "Yes" || echo "No")" >> $BACKUP_DIR/backup-summary.txt
echo "" >> $BACKUP_DIR/backup-summary.txt

# List namespaces that have been backed up
echo "Namespaces with backed up resources:" >> $BACKUP_DIR/backup-summary.txt
find $BACKUP_DIR -name "*.json" | grep -E "(profiles|bindings)" | \
  sed -E 's/.*-(openshift-[^-]+|[^-]+)-[^-]+\.json$/\1/' | sort -u >> $BACKUP_DIR/backup-summary.txt
echo "" >> $BACKUP_DIR/backup-summary.txt

echo "Profiles backed up by type:" >> $BACKUP_DIR/backup-summary.txt
echo "  SeccompProfiles:" >> $BACKUP_DIR/backup-summary.txt
find $BACKUP_DIR/profiles -name "seccompprofiles-*.json" -exec basename {} \; | sort >> $BACKUP_DIR/backup-summary.txt
echo "  SELinuxProfiles:" >> $BACKUP_DIR/backup-summary.txt
find $BACKUP_DIR/profiles -name "selinuxprofiles-*.json" -exec basename {} \; | sort >> $BACKUP_DIR/backup-summary.txt
echo "  RawSELinuxProfiles:" >> $BACKUP_DIR/backup-summary.txt
find $BACKUP_DIR/profiles -name "rawselinuxprofiles-*.json" -exec basename {} \; | sort >> $BACKUP_DIR/backup-summary.txt
echo "" >> $BACKUP_DIR/backup-summary.txt
echo "Profile bindings backed up:" >> $BACKUP_DIR/backup-summary.txt
find $BACKUP_DIR/bindings-recordings -name "*.json" -exec basename {} \; | sort >> $BACKUP_DIR/backup-summary.txt

cat $BACKUP_DIR/backup-summary.txt
```

**Actual output:**
```
=== Backup Summary ===
Total files backed up: 6

SPOD configuration: Yes

Profiles backed up:
rawselinuxprofiles-openshift-security-profiles-errorlogger.json
seccompprofiles-openshift-security-profiles-profile-block-all.json
selinuxprofiles-openshift-security-profiles-errorlogger-selinuxd-test.json

Profile bindings backed up:
profilebindings-openshift-security-profiles-profile-binding-seccomp.json
profilebindings-openshift-security-profiles-profile-binding-selinuxd.json
```

## Step 4: Delete SPO Objects in Order

**IMPORTANT**: Delete profile bindings first to prevent the operator from automatically reapplying profiles to workloads. You also need to make sure there is no activeWorkload in the
profileBinding objects before deleting it.

### Delete Profile Bindings and activeworkloads
```bash
# List all profile bindings across all namespaces
oc get profilebindings -A

# Check all profilebinding activeworkload field
oc get profilebindings -A -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.activeWorkloads)"'

# Check and Delete all workload listed there above


# Delete all profile bindings from all namespaces
for ns in $(oc get profilebindings -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "Deleting profile bindings in namespace: $ns"
  oc delete profilebindings --all -n $ns
done
```

**Actual command and output:**
```bash
Deleting profile bindings in namespace: openshift-security-profiles
profilebinding.security-profiles-operator.x-k8s.io "profile-binding-seccomp" deleted
profilebinding.security-profiles-operator.x-k8s.io "profile-binding-selinuxd" deleted
```

### Update Workloads to Remove Profile References

Next, update all workloads to remove references to SPO profiles. You must either recreate pods without these profiles, or update deployments, statefulset, and other workloads to remove the profile references from their pod templates.


### Delete Security Profiles
```bash
# Delete all security profiles from all namespaces
for resource in seccompprofiles selinuxprofiles rawselinuxprofiles; do
  echo "Checking for $resource in all namespaces..."
  for ns in $(oc get $resource -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
    echo "Deleting $resource in namespace: $ns"
    oc delete $resource --all -n $ns
  done
done
```

**Example output:**
```
Checking for seccompprofiles in all namespaces...
Deleting seccompprofiles in namespace: openshift-security-profiles
seccompprofile.security-profiles-operator.x-k8s.io "profile-block-all" deleted
Checking for selinuxprofiles in all namespaces...
Deleting selinuxprofiles in namespace: openshift-security-profiles
selinuxprofile.security-profiles-operator.x-k8s.io "errorlogger-selinuxd-test" deleted
Checking for rawselinuxprofiles in all namespaces...
Deleting rawselinuxprofiles in namespace: openshift-security-profiles
rawselinuxprofile.security-profiles-operator.x-k8s.io "errorlogger" deleted
```

### Wait for Profile Cleanup
```bash
# Verify all profiles are deleted
oc get seccompprofiles,selinuxprofiles,rawselinuxprofiles -A
```

**IMPORTANT**: If you have any profile recording in progress, you should also remove them, as well as associated active workloads with the profile recordings.
[Manage Profile Recording](https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/security_and_compliance/security-profiles-operator#spo-recording-profiles_spo-seccomp)


## Step 5: Uninstall SPO Operator

### Delete SPO Daemon
```bash
# Delete the spod resource before removing the operator
oc delete spod spod -n openshift-security-profiles
```

### Delete Operator

To uninstall the Security Profiles Operator (SPO) Operator, follow these steps:

### Uninstall via OperatorHub (You can also do that in the CLI)
1. Open the OpenShift Console.
2. Go to **Operators** → **Installed Operators**.
3. Select **Security Profiles Operator** in the `openshift-security-profiles` namespace.
4. Click **Uninstall**.
5. Confirm the uninstallation.

### Run below command to remove the MutatingWebhookConfigurations
```bash
oc delete mutatingwebhookconfigurations spo-mutating-webhook-configuration
```

### Delete Namespace
```bash
oc delete namespace openshift-security-profiles
```

## Step 6: Delete CRDs

```bash
# Delete all SPO CRDs
for crd in seccompprofiles selinuxprofiles rawselinuxprofiles profilebindings profilerecordings securityprofilenodestatuses securityprofilesoperatordaemons apparmorprofiles; do
  if oc get crd ${crd}.security-profiles-operator.x-k8s.io &>/dev/null; then
    echo "Deleting CRD: ${crd}.security-profiles-operator.x-k8s.io"
    oc delete crd ${crd}.security-profiles-operator.x-k8s.io
  else
    echo "CRD ${crd}.security-profiles-operator.x-k8s.io not found"
  fi
done
```

## Step 7: Install New SPO Operator

1. Navigate to OpenShift Console
2. Go to **OperatorHub** → Search for "Security Profiles Operator"
3. Click **Install**
4. Configure installation:
   - Installation mode: **All namespaces on the cluster**
   - Installed Namespace: **openshift-security-profiles**
   - Update approval: **Automatic** (recommended)
5. Click **Install**

### Verify Installation
```bash
# Wait for namespace to be created
until oc get namespace openshift-security-profiles &>/dev/null; do
  echo "Waiting for namespace creation..."
  sleep 5
done

# Check operator deployment
oc get deployment -n openshift-security-profiles
oc get pods -n openshift-security-profiles

# Verify CRDs are installed
oc get crd | grep security-profiles-operator
```

### Restore Custom SPOD Configuration (if applicable)
```bash
# If you had custom spod settings, review and apply them
if [ -f "$BACKUP_DIR/spod-configuration.json" ]; then
  echo "Review your previous spod configuration:"
  cat "$BACKUP_DIR/spod-configuration.json" | jq '.spec'
  
  # Apply custom settings to the new spod (example for verbosity)
  # oc patch spod spod -n openshift-security-profiles --type=merge -p '{"spec":{"verbosity":1}}'
fi
```

## Step 8: Prepare Profiles for Restoration

```bash
# Create directory for prepared profiles
mkdir -p $BACKUP_DIR/profiles-to-restore

# Process each backed up profile
for file in $BACKUP_DIR/profiles/*.json; do
  if [ -f "$file" ]; then
    filename=$(basename "$file")
    profile_type=$(echo "$filename" | cut -d'-' -f1)
    
    # Extract metadata
    name=$(jq -r '.metadata.name' "$file")
    namespace=$(jq -r '.metadata.namespace // "none"' "$file")
    
    echo "Processing: $filename"
    echo "  Type: $profile_type"
    echo "  Name: $name"
    echo "  Original namespace: $namespace"
    
    # Prepare the profile (remove namespace and clean metadata)
    jq 'del(.metadata.namespace) | 
        del(.metadata.resourceVersion) | 
        del(.metadata.uid) | 
        del(.metadata.creationTimestamp) | 
        del(.metadata.generation) | 
        del(.metadata.annotations)
        del(.metadata.labels)
        del(.metadata.managedFields)
        del(.metadata.ownerReferences)
        del(.status) | 
        del(.metadata.finalizers)' "$file" > "$BACKUP_DIR/profiles-to-restore/${profile_type}-${name}.json"
    
    echo "  Prepared for cluster-scoped restoration"
  fi
done
```

## Step 9: Restore Profiles as Cluster-Scoped

```bash
# Restore each prepared profile
for file in $BACKUP_DIR/profiles-to-restore/*.json; do
  if [ -f "$file" ]; then
    echo "Restoring: $(basename "$file")"
    oc apply -f "$file"
  fi
done

# Verify restored profiles
echo ""
echo "Restored profiles:"
oc get seccompprofiles,selinuxprofiles,rawselinuxprofiles
```

**Expected output:**
```
NAME                                                              STATUS      AGE
seccompprofile.security-profiles-operator.x-k8s.io/profile-block-all   Installed   30s

NAME                                                                           USAGE                                            STATE
selinuxprofile.security-profiles-operator.x-k8s.io/errorlogger-selinuxd-test  errorlogger-selinuxd-test.process                Installed

NAME                                                                  USAGE                       STATE
rawselinuxprofile.security-profiles-operator.x-k8s.io/errorlogger    errorlogger.process         Installed
```

## Step 10: Update Workloads to Use Cluster-Scoped Profiles

### For Seccomp Profiles

The path format changes from namespace-scoped to cluster-scoped:
- **Before**: `operator/openshift-security-profiles/profile-block-all.json`
- **After**: `operator/profile-block-all.json`

Example pod spec update:
```yaml
spec:
  containers:
  - name: nginx
    securityContext:
      seccompProfile:
        type: Localhost
        localhostProfile: operator/profile-block-all.json  # No namespace in path
```

### For SELinux Profiles

The type format changes to remove namespace:
- **Before**: `errorlogger-selinuxd-test_openshift-security-profiles.process`
- **After**: `errorlogger-selinuxd-test.process`

Example pod spec update:
```yaml
spec:
  containers:
  - name: nginx
    securityContext:
      seLinuxOptions:
        type: errorlogger-selinuxd-test.process  # No namespace in type
```

## Step 11: Verify Migration Success

### Check Profile Status
```bash
# Check seccomp profile paths
oc get seccompprofiles -o json | jq -r '.items[] | "\(.metadata.name): \(.status.localhostProfile)"'

# Check SELinux profile usage
oc get selinuxprofiles -o json | jq -r '.items[] | "\(.metadata.name): \(.status.usage)"'

# Check raw SELinux profile usage
oc get rawselinuxprofiles -o json | jq -r '.items[] | "\(.metadata.name): \(.status.usage)"'
```


### Test with New Pods
```bash
# Create test pod with seccomp profile
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-seccomp-cluster
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:1.19.1
    securityContext:
      seccompProfile:
        type: Localhost
        localhostProfile: operator/profile-block-all.json
EOF

# Create test pod with SELinux profile
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-selinux-cluster
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:1.19.1
    securityContext:
      seLinuxOptions:
        type: errorlogger-selinuxd-test.process
EOF

# Check pod status
oc get pods test-seccomp-cluster test-selinux-cluster
```

## Troubleshooting

### Profile Not Found
If workloads can't find profiles:
1. Check the exact profile name: `oc get seccompprofiles,selinuxprofiles`
2. Verify profile status: `oc describe seccompprofile <name>`
3. Check operator logs: `oc logs -n openshift-security-profiles -l name=security-profiles-operator`

### Path Format Issues
For seccomp profiles:
- Cluster-scoped format: `operator/<profile-name>.json`
- Check actual path: `oc get seccompprofile <name> -o jsonpath='{.status.localhostProfile}'`

For SELinux profiles:
- Cluster-scoped format: `<profile-name>.process`
- Check actual usage: `oc get selinuxprofile <name> -o jsonpath='{.status.usage}'`

### Profile Distribution
Check if profiles are distributed to nodes:
```bash
oc get securityprofilenodestatuses -o wide
```

## Summary

This migration changes SPO profiles from namespace-scoped to cluster-scoped:

1. **Backup**: All profiles and bindings are backed up with full metadata
2. **Delete Bindings First**: Remove profile bindings to prevent automatic reapplication
3. **Update Workloads**: Remove profile references from workloads
4. **Delete Profiles**: Remove all security profiles
5. **Uninstall/Reinstall**: Fresh operator installation with cluster-scoped CRDs
6. **Restore**: Profiles restored without namespace field
7. **Update**: Workload references updated to new format

Key changes:
- Seccomp: `operator/<namespace>/<profile>.json` → `operator/<profile>.json`
- SELinux: `<profile>_<namespace>.process` → `<profile>.process`
- All profiles are now cluster-wide resources 