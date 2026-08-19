# Deploy the Netskope AI Guardrails on Demand stack.
#
#   1) Copy .env.example to .env and fill in your VPC / subnet / AMI IDs.
#   2) Ensure AWS creds work:  aws sts get-caller-identity
#   3) Run:  ./deploy.ps1
#
# Infrastructure-only: after CREATE_COMPLETE you still activate the appliance
# manually (enroll node + attach service template in the Netskope UI, then the
# VPE CLI dataplane-cert step). See README "After deployment".

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "No .env found. Copy .env.example to .env and fill it in first."
}

# Load .env (KEY=VALUE; skip blanks and # comments).
Get-Content .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}

# Corp TLS-inspection proxy CA bundle, if set in .env (keeps the path out of git).
if ($env:CA_BUNDLE) { $env:AWS_CA_BUNDLE = $env:CA_BUNDLE }

$region = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$stack  = if ($env:STACK_NAME) { $env:STACK_NAME } else { 'netskope-guardrails' }

foreach ($req in 'VPC_ID','ALB_SUBNET_IDS','PRIVATE_SUBNET_IDS','GUARDRAILS_AMI_ID') {
    if (-not (Get-Item "env:$req" -ErrorAction SilentlyContinue).Value) {
        throw "Missing required value '$req' in .env"
    }
}

$overrides = @(
    "VpcId=$env:VPC_ID",
    "AlbSubnetIds=$env:ALB_SUBNET_IDS",
    "PrivateSubnetIds=$env:PRIVATE_SUBNET_IDS",
    "GuardrailsAmiId=$env:GUARDRAILS_AMI_ID"
)
if ($env:GUARDRAILS_INSTANCE_TYPE) { $overrides += "GuardrailsInstanceType=$env:GUARDRAILS_INSTANCE_TYPE" }
if ($env:HOSTED_ZONE_NAME)         { $overrides += "HostedZoneName=$env:HOSTED_ZONE_NAME" }
if ($env:GUARDRAILS_DOMAIN_NAME)   { $overrides += "GuardrailsDomainName=$env:GUARDRAILS_DOMAIN_NAME" }
if ($env:GUARDRAILS_KEY_NAME)      { $overrides += "GuardrailsKeyName=$env:GUARDRAILS_KEY_NAME" }

Write-Host "Deploying stack '$stack' to $region ..."
aws cloudformation deploy `
  --template-file templates/guardrails-standalone.yaml `
  --stack-name $stack `
  --capabilities CAPABILITY_NAMED_IAM `
  --region $region `
  --parameter-overrides $overrides

# Optional org tagging - set any of TAG_OWNER / TAG_PROJECT_TYPE /
# TAG_COST_CENTER / TAG_STAGE / TAG_SENSITIVITY in .env to apply them (only
# the ones you set are applied). Applied as a separate update-stack call -
# NOT via `deploy --tags`. `aws cloudformation deploy` has proven unreliable
# with tags on a stack that already carries them: it errors ("Tag [Key]
# contained invalid characters") when resupplying existing keys, and
# omitting --tags entirely on `deploy` CLEARS all existing stack tags rather
# than leaving them alone (unlike raw update-stack).
$tagMap = @{
    owner        = $env:TAG_OWNER
    'project-type' = $env:TAG_PROJECT_TYPE
    'cost-center'  = $env:TAG_COST_CENTER
    stage        = $env:TAG_STAGE
    sensitivity  = $env:TAG_SENSITIVITY
}
$tags = $tagMap.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "Key=$($_.Key),Value=$($_.Value)" }

if ($tags) {
    # Stack-level tags propagate to every taggable resource in the stack;
    # ASG-launched instances also need PropagateAtLaunch (CloudFormation sets
    # this automatically for stack tags on an AWS::AutoScaling::AutoScalingGroup)
    # - but that only applies at launch time, so an already-running instance
    # from a prior deploy won't retroactively pick up a tag change here
    # without a manual create-tags.
    $tagParams = @(
        'GuardrailsHealthCheckPath','HostedZoneName','GuardrailsMaxCapacity','GuardrailsAmiId',
        'AlbSubnetIds','GuardrailsKeyName','GuardrailsDesiredCapacity','PrivateSubnetIds','VpcId',
        'GuardrailsDomainName','GuardrailsMinCapacity','GuardrailsApiPort','GuardrailsInstanceType'
    ) | ForEach-Object { "ParameterKey=$_,UsePreviousValue=true" }

    Write-Host ""
    Write-Host "Applying tags ..."
    try {
        aws cloudformation update-stack --stack-name $stack --use-previous-template `
          --tags $tags --parameters $tagParams --capabilities CAPABILITY_NAMED_IAM --region $region | Out-Null
        aws cloudformation wait stack-update-complete --stack-name $stack --region $region
    } catch {
        Write-Host "No tag changes to apply (stack already tagged correctly)."
    }
}

Write-Host ""
Write-Host "Done. Stack outputs:"
aws cloudformation describe-stacks --stack-name $stack --region $region `
  --query "Stacks[0].Outputs" --output table
