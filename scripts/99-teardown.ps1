# Tear EVERYTHING down so nothing keeps billing. Run each block ONE AT A TIME.
$env:AWS_PROFILE = 'rosa-lab'; $env:AWS_REGION = 'us-east-1'
$Cluster = 'rosa-lab'

# 1. Delete the cluster (about 10-15 minutes)
rosa delete cluster -c $Cluster --yes
rosa logs uninstall -c $Cluster --watch

# 2. Cluster-specific IAM: operator roles + OIDC provider
rosa delete operator-roles --prefix $Cluster --mode auto --yes
$OidcId = (rosa list oidc-config -o json | ConvertFrom-Json | Select-Object -First 1).id
rosa delete oidc-config --oidc-config-id $OidcId --mode auto --yes

# 3. The VPC stack (NAT gateway bills hourly until this is gone)
#    ROSA HCP can leave a '<cluster-id>-vpce-private-router' security group behind, which blocks VPC deletion. Remove any non-default SGs first.
$vpc = aws ec2 describe-vpcs --filters "Name=tag:aws:cloudformation:stack-name,Values=rosa-lab-net" --query "Vpcs[0].VpcId" --output text
$sgs = aws ec2 describe-security-groups --filters Name=vpc-id,Values=$vpc --query "SecurityGroups[?GroupName!='default'].GroupId" --output text
foreach ($g in $sgs -split '\s+') { if ($g -and $g -ne 'None') { aws ec2 delete-security-group --group-id $g } }
aws cloudformation delete-stack --stack-name rosa-lab-net
aws cloudformation wait stack-delete-complete --stack-name rosa-lab-net

# 4. Verify nothing is left running
rosa list clusters
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId"
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn"
aws ec2 describe-addresses --query "Addresses[].PublicIp"

# Account roles (ManagedOpenShift-HCP-ROSA-*) cost nothing and can stay for next time, or:
# rosa delete account-roles --prefix ManagedOpenShift --hosted-cp --mode auto --yes
