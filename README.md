# Netskope AI Guardrails on Demand ↔ Databricks Unity AI Gateway

Deploy the Netskope **AI Guardrails on Demand** appliance into AWS, and wire
it into the **Databricks Unity AI Gateway External Policy** framework so
Databricks enforces Netskope's guardrail verdicts (prompt injection, unsafe
content, sensitive data, and more) on live model and tool traffic.

This repo is fully self-contained: everything needed to deploy both pieces
end to end lives here — no other repo required.

> **Attribution:** the Guardrails appliance's ALB/DNS/cert pattern and the
> inline self-signed certificate generator are derived from
> [jharris-ns/AWS-AIGW-Reference-Architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture),
> used under the Apache License 2.0. See [`NOTICE`](NOTICE) and
> [`LICENSE`](LICENSE).

> ⚠️ **Beta / private preview.** Netskope AI Guardrails on Demand is a Beta
> feature, and the Databricks External Policy Direct HTTP API is in private
> preview at the time of writing. Contact your Netskope account team to
> enable AI Guardrails on Demand and get the appliance AMI; contact your
> Databricks account team to confirm the External Policies preview is
> enabled on your workspace.

📄 **See [`Netskope-AI-Guardrails-Databricks-Solutions-Guide.docx`](Netskope-AI-Guardrails-Databricks-Solutions-Guide.docx)**
for the full, illustrated, step-by-step deployment guide (architecture
diagram, prerequisites, every step, troubleshooting, and the full API
reference). This README is the quick-reference version.

---

## What gets deployed

Two independent CloudFormation stacks:

**1. The Guardrails appliance** (`templates/guardrails-standalone.yaml`) —
a Netskope Virtual Private Edge (VPE) appliance in a single-instance ASG,
fronted by a private ALB serving HTTPS 443 and forwarding to the appliance's
AI Guardrails API on HTTP `:8080`.

**2. The Databricks adapter** (`templates/databricks-adapter.yaml`) — a
small serverless Lambda that translates between the Databricks External
Policy contract and the Guardrails evaluation API, fronted by API Gateway
and secured with Cognito OAuth2 client-credentials (the only auth method
Databricks' contract supports).

```
Databricks Unity AI Gateway (External Policy)
        │  OAuth M2M bearer token
        ▼
API Gateway + Cognito  →  Lambda (translation adapter)
        │  VPC-internal HTTPS, no NAT needed
        ▼
Internal ALB  →  AI Guardrails on Demand appliance (VPE)  →  Verdict
```

Deploy and activate stack 1 first, then deploy stack 2, then configure
Databricks. See the solutions guide for full detail; `docs/databricks-integration.md`
has the adapter's technical reference (request/response contract, event-type
handling, troubleshooting).

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **VPE appliance AMI** | Netskope-shared "Virtual Private Edge (VPE)" AMI for AI Guardrails on Demand. Typically shared in **us-east-1**. |
| **Netskope tenant w/ Guardrails on Demand** | Beta feature — have Netskope enable it, and configure at least one AI Guardrails profile (you'll need its profile ID). |
| ~~Existing VPC~~ | **Not needed** — `guardrails-standalone.yaml` creates its own VPC, NAT gateway, and all networking. See "Networking" below for the cost trade-off this implies. |
| **EC2 key pair** | Existing key pair in the region, for SSH to the appliance as `nsadmin` (one-time dataplane-cert CLI step). |
| **In-VPC CLI access** | The stack has no bastion. SSH the appliance from a host in the VPC, or over peering/VPN/TGW (`AdditionalClientCidr`) — or use an EC2 Instance Connect Endpoint (see "After deployment"). |
| **Databricks workspace** | Unity Catalog enabled, and the External Policies (Direct HTTP API) private preview enabled — confirm with your Databricks account team. |
| **Databricks permissions** | `CREATE CONNECTION` (or metastore admin) to create the UC HTTP Connection; `MANAGE` on the schema of the service you'll govern. |
| **AWS CLI** | Configured for the target account/region. |

---

## Networking

`guardrails-standalone.yaml` creates its own VPC — the same layout as the
upstream [AWS-AIGW Reference Architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture):
an Internet Gateway, 2 public + 2 private `/24` subnets across two AZs, one
NAT gateway + EIP, route tables, and an S3 gateway endpoint. The ALB and the
appliance both run in the private subnets (no public IP on either). Nothing
to pre-create.

**The trade-off:** the NAT gateway this creates has its own recurring AWS
cost (roughly $32-35/month, plus data processing), separate from however
your organization already pays for NAT elsewhere. For a long-lived
production deployment where reusing an existing VPC/NAT matters more than
zero-prerequisite setup, that's a real fork-point in the template (reintroduce
`VpcId`/subnet parameters), not a flag this repo exposes.

`deploy-databricks-adapter.ps1` auto-discovers the VPC/subnet it needs from
the Guardrails stack's own `VpcId`/`PrivateSubnetIds` outputs, so there's
nothing to wire up manually between the two stacks either.

---

## Quick start

```powershell
# 1. Deploy the Guardrails appliance (creates its own VPC/NAT - see "Networking" above)
cp .env.example .env      # fill in GUARDRAILS_AMI_ID, GUARDRAILS_KEY_NAME
./deploy.ps1

# 2. Activate it manually (see the solutions guide, Part 2) —
#    enroll in the Netskope UI, then set the license key and generate the
#    forward-proxy cert via the VPE CLI over SSH.

# 3. Deploy the Databricks adapter (VPC/subnet auto-discovered from stack 1)
./deploy-databricks-adapter.ps1

# 4. Configure Databricks — create the UC HTTP Connection with the printed
#    outputs, then attach an External policy (see the solutions guide, Part 4,
#    or docs/databricks-integration.md).
```

Prefer raw `aws cloudformation deploy`? Both templates take standard
`--parameter-overrides` — see each template's `Parameters` section, or the
solutions guide's parameter tables.

---

## Parameters

### Guardrails appliance (`templates/guardrails-standalone.yaml`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VpcCidr` | | `10.5.0.0/16` | CIDR for the new VPC (`/16`-`/22`); four `/24` subnets are carved from it. |
| `AdditionalClientCidr` | | *(empty)* | Optional extra CIDR (peered VPC/VPN/TGW) allowed to reach the ALB (443) and appliance (SSH). |
| `GuardrailsAmiId` | ✅ | — | Netskope VPE appliance AMI ID. |
| `GuardrailsKeyName` | ✅ | — | Existing EC2 key pair for SSH as `nsadmin`. |
| `GuardrailsInstanceType` | | `m5.2xlarge` | CPU general-purpose, ≥ 8 vCPU / 32 GiB. **No GPU** — GPU-based detection is a separate, optional VM (not part of this stack). |
| `HostedZoneName` | | `aigw.internal` | Route 53 private zone name (must be unique per VPC). |
| `GuardrailsDomainName` | | `guardrails.aigw.internal` | Internal FQDN; matches the cert CN/SAN. |
| `GuardrailsMinCapacity` / `GuardrailsDesiredCapacity` / `GuardrailsMaxCapacity` | | `1` / `1` / `2` | Appliance instance count. |

### Databricks adapter (`templates/databricks-adapter.yaml`)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VpcId` | ✅ | — | VPC for the adapter Lambda. `deploy-databricks-adapter.ps1` auto-fills this from the Guardrails stack's `VpcId` output — only pass it yourself for raw `aws cloudformation deploy`. |
| `LambdaSubnetIds` | ✅ | — | Subnet(s) in that VPC (no NAT/internet needed). Auto-filled the same way from `PrivateSubnetIds`. |
| `AigodEvaluationUrl` | | `https://guardrails.aigw.internal/api/v2/aiguardrails/evaluation` | Override only if you changed `HostedZoneName`/`GuardrailsDomainName` above. |
| `CertParameterName` | | `/netskope-guardrails/guardrails-cert` | Override only if you used a different `STACK_NAME`. |
| `DefaultProfileId` | | *(blank)* | Optional fallback AI Guardrails profile ID. |

---

## After deployment

**Activation is manual** (Netskope Beta):

1. Confirm the appliance instance is up:
   ```bash
   aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names <stack>-guardrails-asg \
     --query "AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]" \
     --output table
   ```
   > The ASG uses an **EC2** health check (not ELB), so the appliance isn't
   > killed while its API health check is still failing pre-activation.
2. Enroll the node and attach templates in the Netskope UI: *Settings →
   Security Cloud Platform → On-Premises Infrastructure*.
3. SSH in and set the license key + generate the forward-proxy cert (see
   the solutions guide, Part 2, for exact commands). The appliance has no
   public IP and the stack has no bastion — if you have no peering/VPN,
   create an EC2 Instance Connect Endpoint in one of the stack's
   `PrivateSubnetIds` and tunnel through it rather than trying to reach the
   appliance directly.
4. Deploy the Databricks adapter, then configure Databricks (Parts 3–4 of
   the solutions guide, or `docs/databricks-integration.md`).
5. Test (Part 5) — send a benign prompt and a policy-violating prompt
   through the governed Databricks service and confirm ALLOW/DENY.

### Stack outputs

**Guardrails appliance:** `GuardrailsHostUrl`, `GuardrailsAlbDnsName`,
`GuardrailsCertificateArn`, `CertParameterName`, `GuardrailsAsgName`,
`PrivateHostedZoneId`, `VpcId`, `PrivateSubnetIds`, `PublicSubnetIds`,
`NatGatewayPublicIp`.

**Databricks adapter:** `AdapterHost`, `OAuthClientId`, `OAuthTokenEndpoint`,
`OAuthScope`, `UserPoolId` (used to retrieve the Client Secret),
`AdapterFunctionArn`.

---

## Teardown

```bash
aws cloudformation delete-stack --stack-name netskope-databricks-adapter --region us-east-1
aws cloudformation delete-stack --stack-name netskope-guardrails --region us-east-1
```

Delete the adapter stack first (it depends on the appliance's network/cert
resources). De-enroll the node in the Netskope UI separately.

---

## Repository layout

```
templates/
  guardrails-standalone.yaml   The Guardrails appliance CloudFormation template
  databricks-adapter.yaml      The Databricks adapter CloudFormation template
deploy.ps1                     Deploys the Guardrails appliance
deploy-databricks-adapter.ps1  Deploys the Databricks adapter
.env.example                   Copy to .env and fill in for both scripts
docs/
  databricks-integration.md    Adapter technical reference + troubleshooting
  databricks-aigw-flow.excalidraw   Editable diagram of the Databricks-side call flow
Netskope-AI-Guardrails-Databricks-Solutions-Guide.docx   Full illustrated deployment guide
CLAUDE.md                      Guidance for Claude Code working in this repo
NOTICE / LICENSE                Apache-2.0 + attribution to jharris-ns
```

---

## Notes & gotchas

- **The appliance is a VPE, not a container.** No ECR, no GPU on this
  instance — GPU-based detection runs on a separate, optional VM the VPE
  connects to via the service template.
- **This stack creates its own VPC, NAT gateway, and subnets** — see
  "Networking" above. Deleting `netskope-guardrails` tears the VPC down too
  (nothing orphaned to clean up separately), but the NAT gateway bills for
  every hour it exists in the meantime.
- **Activation is manual (Beta).** Neither template enrolls the node or
  generates the dataplane cert — do that via the Netskope UI + VPE CLI.
- **Databricks OAuth M2M is the only supported auth method** for External
  Policies — API keys, Basic auth, and OAuth U2M are not supported. The
  adapter stack provisions Cognito specifically to satisfy this.
- **`config.policy_config` may arrive as a string or an object** — Databricks
  documents it as an opaque pass-through it never parses; the adapter
  normalizes either shape.
- **Built-in Databricks-hosted models often live in a system-owned schema**
  (e.g. `system.ai`) — attaching a policy there needs `MANAGE` on that
  schema, which may need a workspace/account admin grant. To validate the
  integration without waiting on that, attach the policy to a model/provider
  service you've registered yourself first.
- **`aws cloudformation deploy --tags` is unreliable on retagging** — both
  deploy scripts apply optional tags via a separate `update-stack
  --use-previous-template` call instead; see the comments in each script.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
The Guardrails appliance template is derived from
[jharris-ns/AWS-AIGW-Reference-Architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture).
