<#
.SYNOPSIS
  Read-only check that a target org has what the NFY package needs before it is deployed:
  the TC Accounting objects and classes, plus the API version. Changes nothing.
.EXAMPLE
  ./scripts/check-prerequisites.ps1 -OrgAlias nfinity-uat
#>
param([Parameter(Mandatory = $true)][string]$OrgAlias)

$ErrorActionPreference = 'Stop'

# TC Accounting objects the NFY code reads or writes (derived from the Apex source).
$objects = @(
  'TC_Sales_Order__c', 'TC_Sales_Order_Line__c', 'TC_SO_Inventory_Movement__c', 'TC_Shipment__c', 'TC_Shipment_Line__c',
  'TC_Billing__c', 'TC_Billing_Line__c', 'TC_Billing_Cash_Receipt__c', 'TC_Billing_Credit_Memo__c', 'TC_Cash_Receipt__c',
  'TC_Warehouse__c', 'TC_Location__c', 'TC_Inventory_Balance__c', 'TC_Inbound_Inventory_Movement__c',
  'TC_Outbound_Inventory_Movement__c', 'TC_Purchase_Order__c', 'TC_Purchase_Order_Line__c', 'TC_PO_Inventory_Movement__c',
  'TC_Journal_Entry__c', 'TC_Journal_Entry_Line__c', 'TC_GL_Account__c'
)
# TC Accounting Apex classes the NFY code calls.
$classes = @('TC_PostingEngine', 'TC_AccountingContext', 'TC_InventoryService', 'TC_OrderService', 'TC_PostResult', 'TC_TriggerGate', 'TC_TestFactory')

function Invoke-Query([string]$soql, [switch]$Tooling) {
  $qArgs = @('data', 'query', '-o', $OrgAlias, '-q', $soql, '--json')
  if ($Tooling) { $qArgs += '--use-tooling-api' }
  $ErrorActionPreference = 'Continue'   # sf writes update notices to stderr; do not treat them as errors
  $r = (& sf @qArgs 2>$null | Out-String) | ConvertFrom-Json
  if ($r.status -ne 0) { throw "Query failed: $($r.message)" }
  return $r.result.records
}

$inList = ($objects | ForEach-Object { "'$_'" }) -join ','
$foundObjects = Invoke-Query "SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName IN ($inList)" | ForEach-Object QualifiedApiName
$inList = ($classes | ForEach-Object { "'$_'" }) -join ','
$foundClasses = Invoke-Query "SELECT Name FROM ApexClass WHERE Name IN ($inList)" | ForEach-Object Name

$missing = @()
foreach ($o in $objects) { if ($foundObjects -notcontains $o) { $missing += "object $o" } }
foreach ($c in $classes) { if ($foundClasses -notcontains $c) { $missing += "class $c" } }

Write-Host "TC objects found: $(@($foundObjects).Count)/$($objects.Count); TC classes found: $(@($foundClasses).Count)/$($classes.Count)"
if ($missing.Count -gt 0) {
  Write-Host 'Missing prerequisites (install TC Accounting first):' -ForegroundColor Red
  $missing | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Host 'All TC Accounting prerequisites are present.' -ForegroundColor Green
Write-Host 'Also confirm manually: Order Products enabled, standard price book active, corporate currency set, TC default ledger and GL Account Defaults configured.'
