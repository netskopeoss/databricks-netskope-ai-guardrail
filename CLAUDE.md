# CLAUDE.md

Project instructions for Claude Code working in this repository.

## Project overview

This repo deploys the Netskope **AI Guardrails on Demand** service into AWS
and wires it into the **Databricks Unity AI Gateway External Policy**
framework. It is a standalone carve-out of the
[AWS AI Gateway Reference Architecture by jharris-ns](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture)
plus an original Databricks integration adapter — the AI Gateway and DLP On
Demand (DLPoD) components from the upstream project are intentionally not
present.

**AI Guardrails on Demand ships as a Netskope Virtual Private Edge (VPE)
appliance VM** (AMI name like `Virtual Private Edge (VPE) - x.y.z`). It is
*not* a GPU container. The appliance exposes the AI Guardrails on Demand API
on HTTP `:8080` (explicit-proxy mode). GPU-based LLM detection is **optional**
and runs on a **separate** VM the VPE connects to via the service template
(Container URL/IP + OAuth2) — see "Optional GPU backend" below.

**The Databricks adapter is a translation layer**, not a Netskope product —
it's a small Lambda that speaks the Databricks External Policy contract on
one side and the AI Guardrails evaluation API on the other, because the two
speak incompatible schemas.

## Architecture

0. **The template creates its own VPC** — same layout as the upstream
   AWS-AIGW Reference Architecture: Internet Gateway, 2 public + 2 private
   `/24` subnets across two AZs, one NAT gateway + EIP, route tables, and an
   S3 gateway endpoint. The ALB and the appliance both run in the private
   subnets (no public IP on either). No existing VPC/subnets needed — the
   trade-off is a real recurring NAT gateway cost (~$32-35/mo) per
   deployment. See README "Networking" before reverting this to an
   existing-VPC model; it's a deliberate choice, not an oversight.
1. **ASG launches the VPE appliance** from the Netskope-shared VPE AMI on a
   general-purpose CPU instance (≥ 8 vCPU / 32 GiB), in a private subnet.
2. The appliance boots and reaches the **Netskope management plane** outbound
   (via the NAT gateway) to be managed.
3. An **internal ALB**, also in the private subnets, serves **HTTPS 443**
   (self-signed cert) and forwards to the appliance API on **HTTP :8080**;
   **Route 53** resolves the internal domain name to the ALB.
4. **Activation is manual** (Netskope Beta). Verified working sequence:
   1. Enroll the node + attach the **platform** and **AI Guardrails service**
      templates in the Netskope UI (*Settings → Security Cloud Platform →
      On-Premises Infrastructure*). `status tethering` (VPE CLI) should then show
      `cfgagent_connected`, `callhome_reachable`, `required_pods_running` = true.
   2. SSH to the appliance as **`nsadmin`** (publickey only — launch with an EC2
      key pair via the `GuardrailsKeyName` parameter). It drops into the VPE CLI.
      The CLI is restricted: interactive commands typed at the `ns-vpe>` prompt
      work, but the same command passed as a single non-interactive SSH argument
      (`ssh host "status tethering"`) is often rejected — use a forced PTY and
      feed commands via stdin if scripting this (`ssh -tt ...`).
   3. Set the license key: `set system licensekey <key>` (this is the only place
      the license key goes — there is **no** AWS/CloudFormation license step).
   4. Generate the forward-proxy cert (one line, `config` mode):
      `run request certificate generate forward-proxy self-signed common-name "…"
      organization "…" organization-unit "…" city "…" state "…" country "…"
      days 365 email-address "…"`. **This alone brings up the `:8080` listener**
      and flips the ALB target healthy — the service template drives the proxy
      config. Do **not** run the classic DPoP explicit-proxy commands
      (`set dataplane proxy-mode explicit-proxy …`, `set dataplane
      proxy-listener-interface …`); on the VPE those `save`s abort with errors
      like "no proxy mode enabled under dataplane->proxy-mode" and they are not
      needed — that's a different Netskope appliance type's config path.
5. **Deploy the Databricks adapter** (separate stack) once the appliance is
   activated and its target is healthy.
6. **Configure Databricks**: create a UC HTTP Connection using the adapter's
   OAuth M2M credentials, then attach an External Policy to the service you
   want governed. See `docs/databricks-integration.md`.

**Key differences from a from-scratch build:** there are **no** lifecycle
hooks, SNS, Step Functions, tethering/activation Lambdas, paramiko layer, ECR
pull, GPU, or UserData bootstrap on the appliance stack. The only Lambda in
that stack is the inline self-signed-cert custom resource, so deployment is a
single `aws cloudformation deploy` — no S3 artifacts. The adapter stack's
Lambda code is also inlined in its template for the same reason. Activation of
the appliance is done by hand rather than automated, because VPE enrollment is
undocumented/Beta. The ASG uses an **EC2** health check (not ELB) so an
un-activated appliance isn't replaced in a loop.

## Optional GPU backend

GPU-based LLM detection is optional and runs on a **separate** EC2 instance
(a GPU instance type, e.g. `g4dn.xlarge`), **not** part of either
CloudFormation stack in this repo. If you find yourself adding a Deep
Learning AMI, `GuardrailsImageUri`, or GPU instance types to the *appliance*
template, stop — that's the wrong model. The fast path for the GPU host
itself: launch on an AWS **Deep Learning Base GPU AMI** (drivers + Docker +
NVIDIA Container Toolkit preinstalled — skips manual driver installation),
load the vendor-provided `aisecurity-llm` image the customer downloads from
their Netskope tenant UI, run it with `--gpus all`, then set the **Container
URL** in the AI Guardrails service template (in the Netskope UI) to
`http://<gpu-host-private-ip>:8080/invocations`. Register the GPU host's
private IP, not a public one — the VPE reaches it inside the VPC.

## Databricks adapter — hard-won gotchas

These were all discovered by testing against a **live** Databricks workspace,
not just reading the contract doc — trust these over first-principles
reasoning about what "should" work:

- **Response shape must be flat**: `{"result": "ALLOW"|"DENY", "reason": "..."}`.
  Not `{"decision": {"result": ..., "reason": ...}}`. Getting this wrong means
  Databricks can't find `result` at all and fails closed to DENY on *every*
  response, including ones you intended as ALLOW — a very easy bug to miss
  because it "looks" like it should work.
- **`event.type` values are lowercase**: `model_call`, `model_result`,
  `tool_call`, `tool_result`. Not the uppercase enum names you might expect
  from a proto/IDL-style spec.
- **`config.policy_config` may arrive as a JSON-encoded string, not an
  object.** Databricks documents it as an opaque pass-through it "never
  parses" — in practice this means the raw text typed into the UI's "Policy
  configuration" box can be forwarded verbatim as a string. Always normalize
  (try `json.loads` if it's a `str`) before calling `.get()` on it, or you'll
  get a runtime `AttributeError` on every real request while your own
  hand-built tests (which you probably constructed with a real nested object)
  pass fine.
- **The model/tool payload shape varies too** — a real request may use either
  the classic Chat Completions shape (`messages: [{role, content: "..."}]`)
  or the newer Responses API shape (`input: [{role, content: [{type:
  "input_text", text: "..."}]}]`). Handle both, and extract only the
  **current user turn's** text — a naive fallback that dumps the whole
  request/response JSON as text can still "accidentally" produce correct
  verdicts (because the real text is buried in the JSON noise) while giving
  false confidence; verify with a differential test (put a red-herring
  policy-violating phrase in a *prior* turn that should be ignored, confirm
  it doesn't affect the verdict of a benign current turn).
- **OAuth M2M is the only supported auth method.** API keys, Basic auth, and
  OAuth U2M are explicitly not supported by the Databricks contract. Don't
  build a static shared-secret Bearer token scheme — it will not satisfy a
  real customer's UC HTTP Connection setup, which has dedicated fields for
  Client ID / Client Secret / Token endpoint / OAuth scope and nothing else.
  Amazon Cognito's User Pool + Resource Server + client-credentials App
  Client is a fast way to stand up a real OAuth2 token endpoint without
  writing a custom auth server.
- **A plain Lambda Function URL (`AuthType: NONE` + public resource policy)
  may get a blanket 403** from the deploying AWS account/org, even with a
  textbook-correct resource policy — many enterprises block public,
  unauthenticated Function URLs at the account/org level. Route through API
  Gateway instead (it invokes via the `apigateway.amazonaws.com` service
  principal, not a public `"*"` principal), which also conveniently gives you
  a native JWT authorizer for the Cognito token.
- **`aws cloudformation deploy --tags` is unreliable when retagging a stack
  that already has tags with the same keys** — it can fail with a misleading
  "Tag [Key] contained invalid characters" error even when every key/value is
  valid, and separately, *omitting* `--tags` on `deploy` clears all existing
  stack tags rather than leaving them alone (unlike raw `update-stack`).
  Apply/update tags via a separate `aws cloudformation update-stack
  --use-previous-template --tags ...` call instead — both deploy scripts in
  this repo already do this.
- **Databricks propagates policy changes through a config cache** — wait
  60–90 seconds after creating/attaching a policy before testing, or you'll
  get a false "it doesn't work" from testing inside the propagation window.
- **Built-in, Databricks-hosted foundation models often live in a
  Databricks-owned system schema** (commonly `system.ai`). Attaching a policy
  there requires `MANAGE` on that schema, which a regular workspace user may
  not have — it may need a workspace/account admin grant, and might be
  intentionally restricted for system schemas. To validate the whole
  integration without waiting on that grant, register your own model or
  model-provider service (AI Gateway → Providers → add a provider with your
  own API key) in a catalog/schema you own, and attach the policy there
  first.
- **The UC HTTP Connection UI location varies by workspace version.** It has
  been found via **Catalog → gear icon (top of the Catalog panel) →
  Connections**, not via the `Connect` or `Create` buttons in the main
  Catalog Explorer content pane (those are for storage credentials/external
  locations and generic data-source connectors, a different feature). Look
  for a **Policies** tab (marked **Beta**) on the specific model, model
  provider, or MCP service page for attaching the External Policy — not a
  generic schema-level "Policies" page (that one is Unity Catalog's
  unrelated ABAC/row-column-security feature).

## Repository layout

| Path | Purpose |
|------|---------|
| `templates/guardrails-standalone.yaml` | The Guardrails appliance CloudFormation template. |
| `templates/databricks-adapter.yaml` | The Databricks adapter CloudFormation template (Lambda + API Gateway + Cognito). |
| `deploy.ps1` | Deploys the appliance; reads `.env`. |
| `deploy-databricks-adapter.ps1` | Deploys the adapter; reads the same `.env`. |
| `docs/databricks-integration.md` | Adapter technical reference, full request/response contract, troubleshooting. |
| `docs/databricks-aigw-flow.excalidraw` | Editable diagram of the Databricks-side call flow. |
| `Netskope-AI-Guardrails-Databricks-Solutions-Guide.docx` | Full illustrated customer-facing deployment guide. |

## Deployment

```powershell
cp .env.example .env   # fill in your AMI ID / key pair name (no VPC/subnets needed)
./deploy.ps1                       # 1. Guardrails appliance
# ... activate manually (see docs/databricks-integration.md or the solutions guide) ...
./deploy-databricks-adapter.ps1    # 2. Databricks adapter
# ... configure Databricks (UC HTTP Connection + External Policy attachment) ...
```

Both templates are fully self-contained (all Lambda code inlined), so there
is no build step and no S3 upload for either stack.

## Rules & gotchas (appliance)

- **VPE appliance, not a container.** No ECR, no GPU, no `docker run` on this
  instance.
- **CPU sizing:** ≥ 8 vCPU / 32 GiB (default `m5.2xlarge`).
- **AMI region.** Check with your Netskope account team which region the AMI
  is shared in; cross-region copy needs Netskope to also share the backing
  snapshot (and KMS key if encrypted).
- **The template creates its own VPC, NAT gateway, and subnets** — no
  existing VPC required. This means a real recurring NAT gateway cost per
  deployment; see README "Networking" before reverting to an existing-VPC
  model, since that's a deliberate trade-off someone should decide on
  explicitly, not drift back into silently.
- **No bastion in the VPC** — SSH the appliance via an EC2 Instance Connect
  Endpoint in a private subnet, or peering/VPN/TGW (`AdditionalClientCidr`).
- **`HostedZoneName` must be unique per VPC.**
- **Activation is manual (Beta)** — the template does not enroll the node or
  generate the dataplane cert.
- **ASG health check is EC2, not ELB** — deliberate, so the un-activated
  appliance isn't terminated/replaced.
- **Don't commit secrets.** `.env`, `*.pem`, `*.key` are git-ignored.

## Attribution

The Guardrails appliance template is derived from
jharris-ns/AWS-AIGW-Reference-Architecture (Apache-2.0). See `NOTICE` and
`LICENSE`. The Databricks adapter is original work.

## Related resources

- [AI Guardrails on Demand](https://docs.netskope.com/en/ai-guardrails-on-demand)
- [Configuring Virtual Private Edge](https://docs.netskope.com/en/configuring-virtual-private-edge)
- [Netskope AI Gateway Documentation](https://docs.netskope.com/en/ai-gateway/)
- [Upstream reference architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture)
