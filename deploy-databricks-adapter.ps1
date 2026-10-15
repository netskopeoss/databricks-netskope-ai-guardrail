# Deploy the Databricks <-> AI Guardrails on Demand adapter.
#
# Self-contained: the Lambda code is inlined in the template, OAuth M2M
# (Cognito client-credentials) is provisioned automatically, and the ALB
# cert is pulled from SSM at deploy time - no S3 artifacts.
#
#   1) Deploy the Guardrails appliance first (./deploy.ps1) and activate it.
#   2) Run:  ./deploy-databricks-adapter.ps1
#      No VPC_ID/LAMBDA_SUBNET_IDS needed - this script auto-discovers them
#      from the Guardrails stack's own VpcId/PrivateSubnetIds outputs. Only
#      set those in .env if you want to point the adapter at a different/
#      existing VPC instead.
#
# See docs/databricks-integration.md for the Databricks-side setup after
# this completes.
#
# Tags are applied via a separate `update-stack --use-previous-template`
# step, NOT via `deploy --tags` - `aws cloudformation deploy` has proven
# unreliable with tags on a stack that already carries them: it errors
# ("Tag [Key] contained invalid characters") when resupplying keys that
# already exist on the stack, and omitting --tags entirely on `deploy`
# CLEARS all existing stack tags rather than leaving them alone (unlike raw
# update-stack).

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "No .env found. Copy .env.example to .env and fill it in first (see ./deploy.ps1)."
}

Get-Content .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}
if ($env:CA_BUNDLE) { $env:AWS_CA_BUNDLE = $env:CA_BUNDLE }

$region          = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$stack           = if ($env:DATABRICKS_ADAPTER_STACK_NAME) { $env:DATABRICKS_ADAPTER_STACK_NAME } else { 'netskope-databricks-adapter' }
$guardrailsStack = if ($env:STACK_NAME) { $env:STACK_NAME } else { 'netskope-guardrails' }

# Auto-discover the VPC/subnet from the Guardrails stack's own outputs
# (it provisions its own network - see templates/guardrails-standalone.yaml)
# unless overridden in .env (e.g. to point at a different/existing VPC).
$vpcId = if ($env:VPC_ID) { $env:VPC_ID } else {
    aws cloudformation describe-stacks --stack-name $guardrailsStack --region $region `
      --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text
}
$lambdaSubnetIds = if ($env:LAMBDA_SUBNET_IDS) { $env:LAMBDA_SUBNET_IDS } else {
    # PrivateSubnetIds is a comma-joined list (both private subnets) - the
    # adapter template's LambdaSubnetIds param accepts a list, so pass it
    # straight through rather than picking just one.
    aws cloudformation describe-stacks --stack-name $guardrailsStack --region $region `
      --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetIds'].OutputValue" --output text
}
if (-not $vpcId -or -not $lambdaSubnetIds) {
    throw "Could not auto-discover VpcId/PrivateSubnetIds from stack '$guardrailsStack' - " +
          "deploy the Guardrails appliance first (./deploy.ps1), or set VPC_ID / LAMBDA_SUBNET_IDS in .env manually."
}
Write-Host "Using VPC $vpcId / subnet $lambdaSubnetIds (from stack '$guardrailsStack')"

$overrides = @(
    "VpcId=$vpcId",
    "LambdaSubnetIds=$lambdaSubnetIds"
)
if ($env:AIGOD_EVALUATION_URL)  { $overrides += "AigodEvaluationUrl=$env:AIGOD_EVALUATION_URL" }
if ($env:CERT_PARAMETER_NAME)   { $overrides += "CertParameterName=$env:CERT_PARAMETER_NAME" }
if ($env:DEFAULT_PROFILE_ID)    { $overrides += "DefaultProfileId=$env:DEFAULT_PROFILE_ID" }

Write-Host "Deploying stack '$stack' to $region ..."
aws cloudformation deploy `
  --template-file templates/databricks-adapter.yaml `
  --stack-name $stack `
  --capabilities CAPABILITY_IAM `
  --region $region `
  --parameter-overrides $overrides

# Optional org tagging - set any of TAG_OWNER / TAG_PROJECT_TYPE /
# TAG_COST_CENTER / TAG_STAGE / TAG_SENSITIVITY in .env to apply them.
$tagMap = @{
    owner        = $env:TAG_OWNER
    'project-type' = $env:TAG_PROJECT_TYPE
    'cost-center'  = $env:TAG_COST_CENTER
    stage        = $env:TAG_STAGE
    sensitivity  = $env:TAG_SENSITIVITY
}
$tags = $tagMap.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "Key=$($_.Key),Value=$($_.Value)" }

if ($tags) {
    $tagParams = @('DefaultProfileId','VpcId','LambdaSubnetIds','AigodEvaluationUrl','CertParameterName') |
        ForEach-Object { "ParameterKey=$_,UsePreviousValue=true" }

    Write-Host ""
    Write-Host "Applying tags ..."
    try {
        aws cloudformation update-stack --stack-name $stack --use-previous-template `
          --tags $tags --parameters $tagParams --capabilities CAPABILITY_IAM --region $region | Out-Null
        aws cloudformation wait stack-update-complete --stack-name $stack --region $region
    } catch {
        Write-Host "No tag changes to apply (stack already tagged correctly)."
    }
}

Write-Host ""
Write-Host "Done. Stack outputs:"
aws cloudformation describe-stacks --stack-name $stack --region $region `
  --query "Stacks[0].Outputs" --output table

$outputs = aws cloudformation describe-stacks --stack-name $stack --region $region `
  --query "Stacks[0].Outputs" --output json | ConvertFrom-Json
$poolId   = ($outputs | Where-Object OutputKey -eq 'UserPoolId').OutputValue
$clientId = ($outputs | Where-Object OutputKey -eq 'OAuthClientId').OutputValue

Write-Host ""
Write-Host "OAuth Client Secret (keep this out of chat/tickets - treat as a secret):"
aws cognito-idp describe-user-pool-client --user-pool-id $poolId --client-id $clientId --region $region `
  --query "UserPoolClient.ClientSecret" --output text
