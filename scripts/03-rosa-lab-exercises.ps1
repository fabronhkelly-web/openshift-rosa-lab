# Project 4 - Red Hat OpenShift Service on AWS (ROSA HCP): deploy, scale, config, RBAC, and four break-and-fix exercises.
# Run in a NORMAL PowerShell after the cluster is ready and `rosa create admin` has been run:
#   powershell -ExecutionPolicy Bypass -File C:\VMs\lab\p4\rosa-lab.ps1
# It asks for the cluster-admin password (hidden). Output is saved to C:\VMs\lab\p4\rosa-run.log. Secrets are never printed.
$ErrorActionPreference = 'Continue'
$env:AWS_PROFILE = 'rosa-lab'; $env:AWS_REGION = 'us-east-1'
$Cluster = 'rosa-lab'
$Log = 'C:\VMs\lab\p4\rosa-run.log'
$pwSecure = Read-Host 'cluster-admin password (from rosa create admin)' -AsSecureString
$pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwSecure))
Start-Transcript -Path $Log -Force | Out-Null
function Step($t) { Write-Host "`n===================== $t =====================" -ForegroundColor Cyan }
function Run([string]$c) { Write-Host "PS> $c" -ForegroundColor Yellow; Invoke-Expression "$c 2>&1" | Out-Host }
function WaitFor([string]$what, [scriptblock]$test, [int]$secs = 300) {
  $t = 0; while (-not (& $test) -and $t -lt $secs) { Start-Sleep 10; $t += 10 }
  if (& $test) { Write-Host "[ok] $what ($t s)" } else { Write-Host "[timeout] $what after $secs s" }
}

Step "0. Cluster facts (rosa)"
Run "rosa describe cluster -c $Cluster"
Run "rosa list machinepools -c $Cluster"
Run "rosa list idps -c $Cluster"
$api = (rosa describe cluster -c $Cluster -o json | ConvertFrom-Json).api.url
Write-Host "API: $api"
oc login $api -u cluster-admin -p $pw 2>&1 | Select-String 'Login successful|error' | Out-Host
$pw = $null

Step "1. Look around as cluster admin (HCP: control plane is not in your account)"
Run "oc whoami"
Run "oc version"
Run "oc get nodes -o wide"
Run "oc get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone"
Run "oc get clusterversion"
Run "oc get co"
Run "oc get scc"

Step "2. Deploy and expose an app"
Run "oc new-project lab-web"
Run "oc new-app --name=hello registry.access.redhat.com/ubi9/httpd-24~https://github.com/sclorg/httpd-ex.git"
WaitFor "build hello-1 Complete" { (oc get build hello-1 -o jsonpath='{.status.phase}' 2>$null) -eq 'Complete' } 900
Run "oc get builds"
Run "oc rollout status deployment/hello --timeout=300s"
Run "oc expose service/hello"
$route = oc get route hello -o jsonpath='{.spec.host}'
Write-Host "Route: http://$route"
try { $r = Invoke-WebRequest "http://$route" -UseBasicParsing -TimeoutSec 30; Write-Host "HTTP $($r.StatusCode) - $($r.Content.Length) bytes" } catch { Write-Host "HTTP request failed: $($_.Exception.Message)" }
Run "oc get all"

Step "2b. RBAC: least privilege for a developer"
Run "oc adm policy add-role-to-user edit developer -n lab-web"
Run "oc auth can-i create deployments -n lab-web --as=developer"
Run "oc auth can-i delete nodes --as=developer"
Run "oc auth can-i get secrets -n default --as=developer"
Run "oc get rolebindings -n lab-web"

Step "3. Scale and self-heal"
Run "oc scale deployment/hello --replicas=3"
Run "oc rollout status deployment/hello --timeout=180s"
Run "oc get pods -l deployment=hello -o wide"
$victim = (oc get pods -l deployment=hello -o jsonpath='{.items[0].metadata.name}')
Run "oc delete pod $victim --wait=false"
Start-Sleep 20
Run "oc get pods -l deployment=hello"

Step "4. ConfigMap and Secret"
Run "oc create configmap hello-config --from-literal=ENVIRONMENT=lab --from-literal=OWNER=fkelly"
Run "oc create secret generic hello-db --from-literal=DB_PASSWORD=NotARealPassword123"
Run "oc set env deployment/hello --from=configmap/hello-config"
Run "oc set env deployment/hello --from=secret/hello-db"
Run "oc rollout status deployment/hello --timeout=180s"
oc rsh deployment/hello env 2>&1 | Select-String 'ENVIRONMENT|OWNER|DB_PASSWORD' | Out-Host
Write-Host "Secrets are only base64-encoded:"; Run "oc get secret hello-db -o jsonpath='{.data.DB_PASSWORD}'"

Step "5. Break-and-fix 1: ImagePullBackOff"
Run "oc create deployment badimage --image=registry.access.redhat.com/ubi9/httpd-24:doesnotexist"
Start-Sleep 60
Run "oc get pods -l app=badimage"
oc describe pod -l app=badimage 2>&1 | Select-String 'Failed|BackOff|not found|manifest' | Select-Object -First 4 | Out-Host
$cname = oc get deployment badimage -o jsonpath='{.spec.template.spec.containers[0].name}'
Run "oc set image deployment/badimage $cname=registry.access.redhat.com/ubi9/httpd-24:latest"
Run "oc rollout status deployment/badimage --timeout=300s"
Run "oc get pods -l app=badimage"

Step "6. Break-and-fix 2: CrashLoopBackOff"
oc create deployment crashy --image=registry.access.redhat.com/ubi9/ubi-minimal -- /bin/sh -c "echo Starting app; echo ERROR: missing config file /etc/app/app.conf; sleep 5; exit 1" 2>&1 | Out-Host
Start-Sleep 90
Run "oc get pods -l app=crashy"
Run "oc logs deployment/crashy"
Run "oc delete deployment crashy"

Step "7. Break-and-fix 3: image that wants root (SCC restricted-v2)"
Run "oc create deployment rootnginx --image=docker.io/library/nginx:latest"
Start-Sleep 75
Run "oc get pods -l app=rootnginx"
Run "oc logs deployment/rootnginx --tail=5"
$p = oc get pod -l app=rootnginx -o jsonpath='{.items[0].metadata.name}'
Write-Host "SCC applied: $(oc get pod $p -o jsonpath='{.metadata.annotations.openshift\.io/scc}')"
Run "oc delete deployment rootnginx"
# ubi9/nginx-122 is an S2I builder image: started bare it prints usage and exits, so start it with its run script
Run "oc create deployment nginx --image=registry.access.redhat.com/ubi9/nginx-122 --port=8080 -- /usr/libexec/s2i/run"
Run "oc rollout status deployment/nginx --timeout=300s"
Run "oc get pods -l app=nginx"

Step "8. Break-and-fix 4: OOMKilled"
Run "oc set resources deployment/hello --limits=memory=8Mi --requests=memory=8Mi"
Start-Sleep 90
Run "oc get pods -l deployment=hello"
Run "oc get pods -l deployment=hello -o custom-columns=NAME:.metadata.name,LAST_EXIT:.status.containerStatuses[0].lastState.terminated.reason,STATE:.status.containerStatuses[0].state.waiting.reason"
oc get events --sort-by=.lastTimestamp 2>&1 | Select-String 'OOM|memory|Failed' | Select-Object -Last 5 | Out-Host
Run "oc set resources deployment/hello --limits=memory=256Mi --requests=memory=64Mi"
Run "oc rollout status deployment/hello --timeout=300s"
Run "oc get pods -l deployment=hello"

Step "9. Final state"
Run "oc get all"
Run "oc get events --sort-by=.lastTimestamp | Select-Object -Last 15"
Write-Host "Console: $((rosa describe cluster -c $Cluster -o json | ConvertFrom-Json).console.url)"
Write-Host "`nDone. REMEMBER: the cluster bills by the hour - run the teardown steps next."
Stop-Transcript | Out-Null
