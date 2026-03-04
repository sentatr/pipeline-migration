param()

$ErrorActionPreference = "Stop"

# Inputs from CI variables
$hostName        = $env:HOST
$winrmUser       = $env:WINRM_USER
$winrmPass       = $env:WINRM_PASSWORD
$siteName        = $env:IIS_SITE_NAME
$appPoolName     = $env:IIS_APPPOOL_NAME
$deployPath      = $env:DEPLOY_PATH
$backupRoot      = $env:BACKUP_PATH
$healthPath      = $env:HEALTH_URL_PATH
$envName         = $env:ENV_NAME
$artifactDir     = Join-Path $PSScriptRoot "..\package"

if (-not (Test-Path $artifactDir)) { throw "Artifact folder not found: $artifactDir" }

New-Item -ItemType Directory -Force "deploy_logs" | Out-Null
$logFile = "deploy_logs\deploy-$($envName)-$($hostName)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"

function Log($msg) {
  $line = "$(Get-Date -Format o) [$hostName] $msg"
  $line | Tee-Object -FilePath $logFile -Append
}

# Build credential
$sec = ConvertTo-SecureString $winrmPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($winrmUser, $sec)

# Helper: run command on remote host
function Remote($scriptBlock, $args=@()) {
  Invoke-Command -ComputerName $hostName -Credential $cred -ScriptBlock $scriptBlock -ArgumentList $args
}

Log "Starting IIS deployment. Site=$siteName AppPool=$appPoolName DeployPath=$deployPath"

# Step 1: Stop traffic (AppPool + Site)
Log "Stopping IIS site/app pool..."
Remote {
  param($siteName, $appPoolName)
  Import-Module WebAdministration
  if (Test-Path "IIS:\AppPools\$appPoolName") { Stop-WebAppPool -Name $appPoolName }
  if (Test-Path "IIS:\Sites\$siteName")       { Stop-Website -Name $siteName }
} @($siteName, $appPoolName)

# Step 2: Backup current deployment
$backupName = "$siteName-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
Log "Backing up current content to $backupRoot\$backupName.zip ..."
Remote {
  param($deployPath, $backupRoot, $backupName)
  New-Item -ItemType Directory -Force $backupRoot | Out-Null
  $zip = Join-Path $backupRoot "$backupName.zip"
  if (Test-Path $deployPath) {
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $deployPath "*") -DestinationPath $zip -Force
  } else {
    # first-time deploy
    New-Item -ItemType Directory -Force $deployPath | Out-Null
  }
  return $zip
} @($deployPath, $backupRoot, $backupName) | ForEach-Object { Log "Backup created: $_" }

# Step 3: Copy artifact to a staging folder on remote
$remoteStage = "C:\_gitlab_stage\$siteName"
Log "Copying artifact to remote staging: $remoteStage"
Remote {
  param($remoteStage)
  New-Item -ItemType Directory -Force $remoteStage | Out-Null
  Remove-Item (Join-Path $remoteStage "*") -Recurse -Force -ErrorAction SilentlyContinue
} @($remoteStage)

# Use SMB admin share copy (fast & simple). Ensure runner can reach admin share.
$adminSharePath = "\\$hostName\c$\_gitlab_stage\$siteName"
Log "Copying files to $adminSharePath"
New-Item -ItemType Directory -Force $artifactDir | Out-Null
robocopy $artifactDir $adminSharePath /MIR /R:2 /W:2 /NP | Out-Null

# Step 4: Deploy (staging -> deployPath)
Log "Deploying staging to $deployPath"
Remote {
  param($remoteStage, $deployPath)
  New-Item -ItemType Directory -Force $deployPath | Out-Null

  # Recommended: keep deployPath, mirror contents from staging
  robocopy $remoteStage $deployPath /MIR /R:2 /W:2 /NP | Out-Null
} @($remoteStage, $deployPath)

# Step 5: Start traffic (Site + AppPool)
Log "Starting IIS site/app pool..."
Remote {
  param($siteName, $appPoolName)
  Import-Module WebAdministration
  if (Test-Path "IIS:\Sites\$siteName")       { Start-Website -Name $siteName }
  if (Test-Path "IIS:\AppPools\$appPoolName") { Start-WebAppPool -Name $appPoolName }
} @($siteName, $appPoolName)

# Step 6: Warm up + Health check
# If you have host-specific URL, set it via another variable like BASE_URL per environment.
# Here we assume the site is reachable via server name + health path.
$healthUrl = "http://$hostName$healthPath"
Log "Health check: $healthUrl"
try {
  $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 30
  Log "Health OK: HTTP $($resp.StatusCode)"
}
catch {
  Log "Health FAILED. Rolling back from backup..."
  # Rollback: restore last backup zip we created
  Remote {
    param($deployPath, $backupRoot, $backupName, $siteName, $appPoolName)
    Import-Module WebAdministration

    Stop-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue
    Stop-Website -Name $siteName -ErrorAction SilentlyContinue

    $zip = Join-Path $backupRoot "$backupName.zip"
    if (-not (Test-Path $zip)) { throw "Rollback zip not found: $zip" }

    # Clean + restore
    Remove-Item (Join-Path $deployPath "*") -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $deployPath -Force

    Start-Website -Name $siteName -ErrorAction SilentlyContinue
    Start-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue
  } @($deployPath, $backupRoot, $backupName, $siteName, $appPoolName)

  throw "Deployment failed health check and was rolled back on $hostName"
}

Log "Deployment completed successfully."
