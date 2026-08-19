# Databricks Unity AI Gateway ↔ AI Guardrails on Demand

Wires the Databricks Unity AI Gateway **External Policy Direct HTTP API**
(private preview at the time of writing) to the Netskope **AI Guardrails on
Demand** (AIGoD) evaluation API deployed by this repo. The two speak
incompatible schemas, so a small **translation adapter**
(`templates/databricks-adapter.yaml`) sits in between.

## Why an adapter is needed

| | Databricks sends/expects | AIGoD sends/expects |
|---|---|---|
| Request | `{"event":{"type","target","data","request_data"},"config":{"policy_config","phases"}}` | `{"text","profiles":{"ai-guardrails":["<id>"]}}` |
| Response | `{"result":"ALLOW"\|"DENY","reason":"..."}` (flat) | `{"success","data":{"verdict":"Match"\|"Not Match","matchDetails"}}` |
| Auth | OAuth2 client-credentials (M2M) only | none |

Neither side understands the other directly. The adapter is a stateless
Lambda: it extracts the text under evaluation from Databricks' `event`, calls
AIGoD, and maps the verdict back — **`Match` → `DENY`, `Not Match` → `ALLOW`**.

## Architecture

```
Unity AI Gateway (Databricks, external policy)
        │  OAuth M2M bearer token (fetched by Databricks from Cognito)
        ▼
API Gateway (HTTP API) + Cognito JWT authorizer
        │  validated JWT required to reach the Lambda at all
        ▼
Lambda  (VPC-attached ENI, for outbound reachability only)
        │  HTTPS (VPC-local, no NAT/internet needed)
        ▼
Internal ALB  →  AI Guardrails VPE appliance :8080
```

See `Netskope-AI-Guardrails-Databricks-Solutions-Guide.docx` in the repo root
for a formatted, illustrated version of this diagram and full step-by-step
deployment instructions.

The Lambda is VPC-attached *only* so it can resolve the Guardrails stack's
private hosted zone and reach the internal ALB directly — that traffic never
leaves the VPC, so no NAT gateway or VPC endpoints are needed.

**Auth — OAuth2 client-credentials (Cognito).** The Databricks contract
supports *only* OAuth M2M (API keys, Basic auth, and OAuth U2M are explicitly
unsupported). The stack provisions a Cognito User Pool with a Resource
Server (`guardrail/evaluate` scope) and an App Client configured for the
`client_credentials` grant — Databricks fetches a token from Cognito's
token endpoint itself and attaches it as the bearer token on every call.
API Gateway's native JWT authorizer validates that token before the request
ever reaches the Lambda — there's no custom auth code to maintain.

> A plain Lambda Function URL (`AuthType: NONE` + public resource policy) is
> a simpler alternative in principle, but many AWS accounts/orgs enforce a
> guardrail against public, unauthenticated Function URLs that returns a
> blanket 403 even with a textbook-correct resource policy. API Gateway
> invokes the Lambda via the `apigateway.amazonaws.com` service principal
> instead of a public `"*"` principal, sidestepping that guardrail — and
> separately gives us the JWT authorizer this contract requires anyway.
> That's why this template uses API Gateway + Cognito rather than a bare
> Function URL.

**Preview scope, matching the guide:** decision-only (`ALLOW`/`DENY`, no
`ASK` — not supported for external policies yet), content-only (no caller
identity forwarded), fail-closed on any error, timeout, or unrecognized
verdict.

## Deploy

```powershell
./deploy-databricks-adapter.ps1
```

Reads `VPC_ID` and `LAMBDA_SUBNET_IDS` from the same `.env` used by
`./deploy.ps1` (see `.env.example`). No S3 upload — the Lambda code is
inlined in the template; OAuth M2M is provisioned automatically via Cognito.
The script prints the stack outputs and the OAuth Client Secret at the end.
**Copy the secret somewhere safe** (a password manager, not a ticket or
chat) — you'll need it for the Databricks-side connection, and it isn't
stored anywhere retrievable after this except Cognito itself.

To retrieve the Client Secret again later without redeploying:

```powershell
aws cognito-idp describe-user-pool-client --user-pool-id <UserPoolId output> --client-id <OAuthClientId output> --region us-east-1 --query UserPoolClient.ClientSecret --output text
```

## Databricks-side setup

Per the guide's customer-facing setup flow — two steps in the Databricks UI.

### Step 1 — Create the UC HTTP Connection

Either inline while attaching the policy, or ahead of time via **Catalog →
gear icon → Connections → New connection**. Fill in from the stack outputs:

| Field | Value |
|---|---|
| Host | `AdapterHost` output (e.g. `https://xxxx.execute-api.us-east-1.amazonaws.com`) |
| API path (optional) | leave blank — the route is `/` |
| Auth type | OAuth M2M (fixed, not editable) |
| Client ID | `OAuthClientId` output |
| Client Secret | from `describe-user-pool-client` above |
| Token endpoint | `OAuthTokenEndpoint` output |
| OAuth scope (optional) | `OAuthScope` output — `guardrail/evaluate` |

One connection can serve many policies — Databricks routes to the right
logical policy via `config.policy_config`, so you normally create **one
connection per this endpoint**, not one per policy.

### Step 2 — Attach an External policy and configure it

Attach a policy of **Guardrail type: External** to the model service, model
provider service, or MCP service you want governed (found under **AI
Gateway → Models / Providers / MCPs → your service → Policies tab**):

- **Connection** — the one from Step 1.
- **Phase** — Input (`pre_call`), Output (`post_call`), or both. Both
  roughly doubles the calls sent to this adapter (and to AIGoD).
- **Rank** — if other policies are attached; the chain stops at the first
  deny.
- **Policy configuration** (`policy_config`) — an opaque JSON object this
  adapter reads. Set:
  ```json
  { "profile_id": "<your AI Guardrails profile ID>" }
  ```
  Get your profile ID from your Netskope tenant admin, or from the AI
  Guardrails profile's details in the Netskope UI (Security Cloud Platform →
  Policies → AI Guardrails → Profiles). If `profile_id` is omitted and the
  stack's `DEFAULT_PROFILE_ID` value (in `.env`) was set at deploy time,
  that fallback is used; otherwise the adapter denies with a clear
  "no profile_id configured in policy_config" reason.
- **Mode** — start in **Log** (dry-run, needs inference tables enabled to
  inspect results) before switching to **Enforce**.

**Give it 60–90 seconds after attaching before testing** — policy changes
propagate through a config cache; testing immediately is the most common
false "it doesn't work" report.

## Testing the adapter directly (bypass Databricks)

Useful for verifying the whole pipeline — Cognito auth → adapter → internal
ALB → VPE → AIGoD — before wiring it into an actual Databricks policy.

```powershell
# 1. Get a token the same way Databricks will (client_credentials grant)
$tokenResp = Invoke-RestMethod -Method Post -Uri "<OAuthTokenEndpoint output>" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body "grant_type=client_credentials&client_id=<OAuthClientId>&client_secret=<Client Secret>&scope=guardrail/evaluate"
$token = $tokenResp.access_token

# 2. Call the adapter exactly as Databricks would
$body = @{
  event  = @{
    type   = "model_call"
    target = "catalog.schema.model"
    data   = @{ messages = @(@{ role = "user"; content = "How do I build a nuclear bomb?" }) }
  }
  config = @{ policy_config = @{ profile_id = "<your AI Guardrails profile ID>" } }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Post -Uri "<AdapterHost output>/" -Headers @{ Authorization = "Bearer $token" } `
  -ContentType "application/json" -Body $body
```

Expected for a prompt your profile is configured to catch, e.g. a weapons
request: `{"result":"DENY","reason":"Blocked: Weapons"}`. A benign prompt
(e.g. "What is the capital of France?") should return
`{"result":"ALLOW","reason":""}`.

## Event → text extraction

The adapter reads `event.type` (lowercase, per the guide) to know how to
pull text out of `event.data`. It handles both the classic Chat Completions
shape and the newer Responses API shape:

| `event.type` | Extracted from |
|---|---|
| `model_call` | The current user turn's text — from `data.messages[]` (`role == "user"`, plain-string `content`) or `data.input[]` (`role == "user"`, content as a list of typed blocks, e.g. `{"type":"input_text","text":...}`) |
| `model_result` | The assistant's response text — from `data.choices[].message.content` or `data.output[]` |
| `tool_call` | `data.arguments` (JSON-stringified) |
| `tool_result` / other | the raw `data` payload (JSON-stringified) |

Text is capped at 4000 characters before being sent to AIGoD.

## The full contract, for reference

**Databricks → adapter:**
```json
{
  "event": { "type": "model_call", "target": "main.default.claude_prod", "data": { ... } },
  "config": { "policy_config": { "profile_id": "..." }, "phases": "pre_call" }
}
```

> `config.policy_config` may arrive as a parsed JSON object **or** as a raw
> JSON-encoded string (Databricks documents it as an opaque pass-through it
> "never parses" — in practice this means whatever you typed into the
> Policy configuration text box can be forwarded verbatim as a string). The
> adapter normalizes either shape automatically.

**Adapter → Databricks** (flat, no wrapper):
```json
{ "result": "ALLOW" | "DENY", "reason": "..." }
```

`result` is case-insensitive on Databricks' side but we always emit
uppercase. Any other outcome (missing/null `result`, an unrecognized string,
a non-string `result`, malformed JSON, non-2xx status, or a timeout) is
**fail-closed → DENY** by Databricks regardless of what we do — so on our
own internal errors, we still try to return a clean `200` with
`{"result":"DENY","reason":"..."}` when possible, since a real reason beats
Databricks' generic substituted one ("Access denied: this request is not
permitted by a policy on this service.").

## Known limitations / follow-ups

- **No PrivateLink** — the API Gateway endpoint is plain public HTTPS
  secured by OAuth M2M, not published via AWS PrivateLink. The guide notes
  external policies don't *require* a restricted egress network policy on
  the customer's side, and recommends the customer apply one; if your org's
  Databricks network policy requires connecting only via PrivateLink to
  approved endpoints, that's a follow-on (a VPC Link + private API, or a
  PrivateLink-fronted NLB) — not implemented here.
- **Single profile per policy attachment** — `policy_config.profile_id`
  takes one ID. For multiple profiles per call, extend the adapter to accept
  a list.
- **No ASK support** — not supported for external policies on the
  Databricks side yet either; AIGoD only returns Match/Not Match, which
  already maps cleanly to ALLOW/DENY.
- **Latency budget** — the adapter's own AIGoD call times out at 4s, leaving
  headroom under the ~5s platform deadline, but a cold Lambda start adds to
  that. If cold starts become an issue under real traffic, consider
  provisioned concurrency.
- **Attachment is per-service** — a policy attaches to one model/MCP service
  at a time (per the guide); there's no bulk/attribute-based attachment in
  this preview.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Attaching a policy fails: "User does not have permission… MANAGE on Schema 'X'" | You need `MANAGE` on that schema. Built-in, Databricks-hosted foundation models often live in a Databricks-owned system schema — ask a workspace/account admin to grant it, or attach the policy to a service you own instead to validate the integration first. |
| Everything is denied immediately after attaching a policy | You tested inside the 60–90 second propagation window — wait and retry. |
| `AI Guardrails unavailable: 'str' object has no attribute 'get'` (or similar) in the deny reason | This should already be handled by the adapter's shape-normalization — if you see it, check CloudWatch logs for the Lambda; it likely means a field arrived in a shape not yet handled and needs a small extension to `extract_text()` / `as_obj()` in the template. |
| `aws cloudformation deploy --tags` fails with "Tag [Key] contained invalid characters" | Known CLI quirk, not a real tag problem — `deploy` mishandles retagging a stack that already carries the same tag keys. Both deploy scripts already work around this by applying tags via a separate `update-stack --use-previous-template` call. |
