# OpenShift on AWS (ROSA HCP) – Deploy, Operate, Troubleshoot

Hands-on lab on **Red Hat OpenShift Service on AWS (ROSA) with hosted control planes**: account setup with least-privilege STS roles, cluster build, app deployment, scaling, configuration, RBAC, four break-and-fix scenarios, and a full teardown with cost verification.

> Part of a four-project home lab: [RHEL 9 STIG hardening](https://github.com/fabronhkelly-web/rhel9-stig-hardening) · [Ansible automation](https://github.com/fabronhkelly-web/rhel9-ansible-project) · [Red Hat IdM](https://github.com/fabronhkelly-web/rhel9-idm-lab) · OpenShift (this repo)

## Why ROSA instead of OpenShift Local
The lab host is Windows 11 **Home** (no Hyper-V), and nested virtualization under VMware is blocked while the Windows hypervisor is active. Instead of fighting the host, I ran OpenShift as a managed service on AWS – the same model many DoD and federal programs use (ROSA is also offered in AWS GovCloud).

## Architecture
| Item | Choice | Why |
|---|---|---|
| Control plane | Hosted by Red Hat (HCP) | Faster build (~15 min), lower cost, no masters to patch |
| Workers | 2 × m5.xlarge, single AZ | Enough for the lab; HA would use 3 AZs |
| Auth to AWS | AWS IAM Identity Center (SSO) | No long-lived access keys on the workstation |
| Cluster → AWS | STS + OIDC operator roles | Each operator gets its own short-lived, scoped role |
| Network | VPC from `rosa create network` (public + private subnet, NAT) | Workers live in the private subnet |
| Cost guardrail | AWS Budget alert at $20 | Lab cost target under $10 |

## Scripts
| Script | What it does |
|---|---|
| `scripts/00-prereqs.ps1` | Installs `rosa`/`oc`, Red Hat login, links accounts, account-wide roles |
| `scripts/01-create-cluster.ps1` | OIDC config, VPC, operator roles, cluster, temporary cluster-admin |
| `scripts/03-rosa-lab-exercises.ps1` | All exercises below, logged to a transcript (password prompt is hidden, never logged) |
| `scripts/99-teardown.ps1` | Deletes cluster, roles, OIDC, VPC and verifies nothing is still billing |

## Exercises
1. **Look around** – nodes, cluster version, cluster operators, SCCs.
2. **Deploy and expose** – Source-to-Image build from Git (`ubi9/httpd-24`), route, HTTP test.
3. **RBAC** – grant `edit` in one project and prove least privilege with `oc auth can-i --as=developer`.
4. **Scale and self-heal** – 3 replicas, delete a pod, watch the ReplicaSet replace it.
5. **ConfigMap and Secret** – inject as env vars; show Secrets are only base64-encoded.
6. **Break-and-fix: ImagePullBackOff** – bad tag → diagnose with `describe` → `oc set image`.
7. **Break-and-fix: CrashLoopBackOff** – read `oc logs --previous` to find the cause.
8. **Break-and-fix: SCC** – a root-only image fails under `restricted-v2`; fix with a non-root UBI image instead of granting `anyuid`.
9. **Break-and-fix: OOMKilled** – 8 Mi limit → `lastState.terminated.reason=OOMKilled` → right-size limits.

## Results (run on Nov 25, 2026)
Full redacted transcript: [`logs/rosa-run-redacted.txt`](logs/rosa-run-redacted.txt)

| Item | Result |
|---|---|
| Cluster | ROSA HCP, **OpenShift 4.22.22** (Kubernetes 1.35), control plane MultiAZ (hosted by Red Hat), data plane 2 × m5.xlarge on RHEL CoreOS 9.8, OVN-Kubernetes |
| Build time | Hosted control plane available **8 minutes** after `rosa create cluster`; all **22 cluster operators** Available |
| S2I deploy | `ubi9/httpd-24` + Git source built in **27 s**; route returned **HTTP 200** |
| RBAC | `developer` with `edit` in `lab-web`: create deployments **yes** · delete nodes **no** · read secrets in `default` **no** |
| Scale / self-heal | 3 replicas spread across both workers; a deleted pod was replaced and Running within ~20 s |
| ConfigMap / Secret | Injected as env vars; showed the Secret is only base64 (`Tm90QVJl...`), so etcd encryption and RBAC matter |
| ImagePullBackOff | Bad tag → `manifest unknown` in `oc describe` → `oc set image` → Running |
| CrashLoopBackOff | `oc logs` showed the cause: `ERROR: missing config file /etc/app/app.conf` |
| SCC | Docker Hub `nginx` failed under **restricted-v2**: `mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)`. Fixed with a non-root Red Hat UBI image instead of granting `anyuid` |
| OOMKilled | 8 Mi limit → `lastState.terminated.reason = OOMKilled` → right-sized to 64 Mi request / 256 Mi limit → 3/3 Running |

### Findings
- **The "fixed" nginx also crash-looped at first.** `ubi9/nginx-122` is an S2I *builder* image: started without source it prints its usage text and exits. Fix: start it with its run script (`oc create deployment ... -- /usr/libexec/s2i/run`) → `1/1 Running`. Lesson: read the logs before assuming the fix worked.
- **`oc logs --previous` came back empty** for a container that exited instantly (already garbage-collected). Reading the current container's logs, or keeping it alive a few seconds, gave the root cause.
- **Hardening gap:** `rosa describe cluster` showed `EC2 Metadata Http Tokens: optional` (IMDSv1 allowed on workers). `scripts/01-create-cluster.ps1` now passes `--ec2-metadata-http-tokens required`. Etcd encryption and audit-log forwarding were also off; for production, enable them (`--etcd-encryption`, audit log forwarding to CloudWatch).

## Issues hit and how I fixed them
| Problem | Cause | Fix |
|---|---|---|
| OpenShift Local MSI refused to install | Windows 11 Home has no Hyper-V | Moved to ROSA |
| VMware VM: "Virtualized Intel VT-x/EPT is not supported" | Windows hypervisor (WHP) active, blocks nested virt | Moved to ROSA |
| `rosa create account-roles` → `Insufficient AWS quotas` | New account: 32 vCPU On-Demand Standard quota, ROSA checks for 100 | Service Quotas increase request to 100 |
| Network stack `DELETE_FAILED` on the VPC | Orphaned `...-vpce-private-router` security group left by the cluster | Found it with `describe-security-groups --filters vpc-id`, deleted it, reran `delete-stack` |
| `ubi9/nginx-122` CrashLoopBackOff after the SCC fix | S2I builder image exits after printing usage when run without source | Start it with `/usr/libexec/s2i/run` |
| `Invoke-WebRequest` download crawled | Windows PowerShell progress bar overhead | `curl.exe -L -o` |
| Quota request went to an AWS Support case (32 → 100 vCPU) | Newer account, manual review | Replied on the case with the ROSA use case; approved in about 6 days |
| `rosa whoami`: access and refresh tokens expired | Red Hat CLI token expired after a week idle | `rosa login --use-auth-code` again (AWS SSO also needed `aws sso login`) |
| `rosa list account-roles` failed with `unknown flag: --mode` | The next pasted command was appended to a line still waiting at the prompt | Run interactive or long commands one at a time; reran `create oidc-config` alone |
| `rosa create cluster`: No valid billing account associated | AWS and Red Hat accounts were never linked for billing (the console button was blocked while the quota was pending) | ROSA console → Get started → **Continue to Red Hat** → linked; reran the create |

## Teardown and cost
| Step | Result |
|---|---|
| `rosa delete cluster` | Uninstalled in **9 minutes** (12:19 → 12:28) |
| Operator roles, OIDC provider, OIDC config | Deleted (account-wide roles kept: free IAM roles, reusable) |
| `rosa-lab-net` CloudFormation stack | First attempt **DELETE_FAILED**: the VPC was blocked by an orphaned security group (`<cluster-id>-vpce-private-router`) that ROSA created for the PrivateLink path to the hosted control plane. Deleted it by hand, reran `delete-stack` → deleted |
| Final verification | No clusters, NAT gateways, running instances, load balancers, Elastic IPs or VPC left |

**Cost estimate:** cluster up about 1.4 h (ROSA HCP fee + 2 × m5.xlarge) plus NAT gateway about 2 h ≈ **$2–3 total**, well under the $20 budget alert. (Final figure: Cost Explorer, 1–2 days later.)

**Lesson:** always verify teardown. `rosa delete cluster` reported success, but the network stack still failed on a resource the cluster left behind. A teardown script that doesn't check would have left a VPC (and, until it deleted, a NAT gateway) behind.

## Security notes
- No AWS keys, pull secrets, passwords or kubeconfigs are in this repo (`.gitignore` blocks them).
- AWS account ID and Red Hat org ID are redacted from logs and screenshots.
- `cluster-admin` from `rosa create admin` is a break-glass htpasswd user for the lab; in production you would use an OIDC IdP (Entra ID / Okta / Keycloak) and delete it.
