# One-time account setup for ROSA with hosted control planes (HCP). Run each block ONE AT A TIME.
# Prereqs: AWS CLI v2 with an IAM Identity Center (SSO) profile, ROSA enabled in the AWS console,
# EC2 "Running On-Demand Standard" vCPU quota >= 100 in the region.
$env:AWS_PROFILE = 'rosa-lab'; $env:AWS_REGION = 'us-east-1'

# 1. Install rosa + oc (curl.exe is much faster than Invoke-WebRequest)
New-Item -ItemType Directory C:\Tools\rosa -Force | Out-Null
curl.exe -L -o $env:TEMP\rosa.zip https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-windows.zip
Expand-Archive $env:TEMP\rosa.zip C:\Tools\rosa -Force
curl.exe -L -o $env:TEMP\oc.zip https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-windows.zip
Expand-Archive $env:TEMP\oc.zip C:\Tools\rosa -Force
$env:Path += ";C:\Tools\rosa"

# 2. Log in to Red Hat (opens a browser)
rosa login --use-auth-code
rosa whoami
rosa verify quota

# 3. Link AWS <-> Red Hat and create the account-wide IAM roles
rosa create ocm-role --mode auto --yes
rosa create user-role --mode auto --yes
rosa create account-roles --hosted-cp --mode auto --yes
