<#
.SYNOPSIS
  Validate (default) or deploy the NFY Salesforce package with its own tests.
.EXAMPLE
  ./scripts/deploy-salesforce.ps1 -OrgAlias nfinity-uat            # check-only validation, changes nothing
  ./scripts/deploy-salesforce.ps1 -OrgAlias nfinity-uat -Deploy    # real deployment
#>
param(
  [Parameter(Mandatory = $true)][string]$OrgAlias,
  [switch]$Deploy
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $root 'salesforce')
try {
  $tests = Get-ChildItem 'force-app/main/default/classes' -Filter '*_Test.cls' | ForEach-Object { $_.BaseName }
  $testArgs = $tests | ForEach-Object { '--tests'; $_ }
  $verb = if ($Deploy) { 'start' } else { 'validate' }
  Write-Host "sf project deploy $verb to $OrgAlias with $($tests.Count) test classes"
  & sf project deploy $verb --target-org $OrgAlias --source-dir force-app --test-level RunSpecifiedTests @testArgs --wait 60
  if ($LASTEXITCODE -ne 0) { throw "Deployment $verb failed (exit $LASTEXITCODE)." }
} finally {
  Pop-Location
}
