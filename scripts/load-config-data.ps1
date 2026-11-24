<#
.SYNOPSIS
  Upserts the integration catalogue (systems, then flows) from config/seed into a target org.
  Matches on Code__c, so running it twice changes nothing new. Edit the CSVs first
  (Environment__c, Workato_Recipe_Id__c) for the target environment.
.EXAMPLE
  ./scripts/load-config-data.ps1 -OrgAlias nfinity-uat
#>
param([Parameter(Mandatory = $true)][string]$OrgAlias)

$ErrorActionPreference = 'Stop'
$seed = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/seed'

foreach ($obj in 'NFY_Integration_System__c', 'NFY_Integration_Flow__c') {
  $file = Join-Path $seed "$obj.csv"
  Write-Host "Upserting $obj from $file"
  & sf data upsert bulk --target-org $OrgAlias --sobject $obj --file $file --external-id Code__c --wait 10
  if ($LASTEXITCODE -ne 0) { throw "Upsert of $obj failed (exit $LASTEXITCODE)." }
}
Write-Host 'Done. Link each TC_Warehouse__c to its operator system (NFY_System__c) as in config/warehouse-mapping.csv.'
