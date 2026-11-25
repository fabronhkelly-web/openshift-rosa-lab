# Build the cluster. Run each block ONE AT A TIME and check the output before moving on.
$env:AWS_PROFILE = 'rosa-lab'; $env:AWS_REGION = 'us-east-1'
$Cluster = 'rosa-lab'

# 1. OIDC provider used by the operator roles (STS, no long-lived keys in the cluster)
rosa create oidc-config --mode auto --yes
$OidcId = (rosa list oidc-config -o json | ConvertFrom-Json | Select-Object -First 1).id

# 2. VPC with one public + one private subnet (CloudFormation stack built by rosa)
rosa create network --param Name=rosa-lab-net --param Region=us-east-1 --param AvailabilityZoneCount=1 --param VpcCidr=10.0.0.0/16
# Collect the two subnet IDs the stack created:
$Subnets = (aws ec2 describe-subnets --filters "Name=tag:aws:cloudformation:stack-name,Values=rosa-lab-net" --query "Subnets[].SubnetId" --output text) -replace '\s+', ','

# 3. Operator roles (one IAM role per cluster operator, scoped by the OIDC provider)
$Installer = (aws iam get-role --role-name ManagedOpenShift-HCP-ROSA-Installer-Role --query Role.Arn --output text)
rosa create operator-roles --hosted-cp --prefix $Cluster --oidc-config-id $OidcId --installer-role-arn $Installer --mode auto --yes

# 4. The cluster (needs AWS and Red Hat accounts linked for billing: ROSA console -> Get started -> Continue to Red Hat): 2 x m5.xlarge workers, control plane hosted by Red Hat
$Acct = (aws sts get-caller-identity --query Account --output text)
rosa create cluster --cluster-name $Cluster --sts --hosted-cp --mode auto --yes `
  --oidc-config-id $OidcId --operator-roles-prefix $Cluster --subnet-ids $Subnets `
  --region us-east-1 --compute-machine-type m5.xlarge --replicas 2 --billing-account $Acct --ec2-metadata-http-tokens required
rosa logs install -c $Cluster --watch
rosa describe cluster -c $Cluster

# 5. Temporary cluster-admin (htpasswd IdP). Save the password it prints somewhere private.
rosa create admin -c $Cluster
