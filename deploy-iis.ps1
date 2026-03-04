param()

$ErrorActionPreference = "Stop"

$hostName    = $env:HOST
$envName     = $env:ENV_NAME

$winrmUser   = $env:WINRM_USER
$winrmPass   = $env:WINRM_PASSWORD

$siteName    = $env:IIS_SITE_NAME
$appPoolName = $env:IIS_APPPOOL_NAME
$deployPath  = $env:DEPLOY_PATH
$backupRoot  = $env:BACKUP_PATH
$healthUrl   = $env:HEALTH_URL

if (-not $hostName)    { throw "HOST is required." }
if (-not $winrmUser -or -not $winrmPass) { throw "WINRM_USER/WINRM_PASSWORD required." }
if (-not $siteName)    { throw "IIS_SITE_NAME required." }
if (-not $appPoolName) { throw "IIS_APPPOOL_NAME required." }
if (-not $deployPath)  { throw "DEPLOY_PATH required." }
if (-not $backupRoot)  { throw "BACKUP_PATH required." }

# If HEALTH_URL is host-based, you can set HEALTH_URL like: http://{HOST}/health
if ($healthUrl -and $healthUrl.Contains("{HOST}")) {
  $healthUrl = $healthUrl.Replace("{HOST}", $hostName)
}

New-Item -ItemType Directory -Force "deploy_logs" | Out-Null
$logFile = "deploy_logs\deploy-$envName-$hostName-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"

function Log($msg) {
  $line = "$(Get-Date -Format o) [$envName][$hostName] $msg"
  $line | Tee-Object -FilePath $logFile -Append
}

# Prepared payload from previous stage
$payload = Join-Path $PSScriptRoot "..\work\payload"
if (-not (Test-Path $payload)) { throw "Prepared payload not found: $payload" }

# Credential
$sec  = ConvertTo-SecureString $winrmPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($winrmUser, $sec)

function Remote($sb, $args=@()) {
  Invoke-Command -ComputerName $hostName -Credential $cred -ScriptBlock $sb -ArgumentList $args
}

Log "Starting deployment."
Log "Site=$siteName AppPool=$appPoolName DeployPath=$deployPath"

# 1) Stop IIS
Log "Stopping IIS site/app pool..."
Remote {
  param($siteName, $appPoolName)
  Import-Module WebAdministration
  if (Test-Path "IIS:\Sites\$siteName")       { Stop-Website -Name $siteName -ErrorAction SilentlyContinue }
  if (Test-Path "IIS:\AppPools\$appPoolName") { Stop-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue }
} @($siteName, $appPoolName)

# 2) Backup current deployment
$backupName = "$siteName-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
Log "Backing up current deployment to $backupRoot\$backupName.zip"
Remote {
  param($deployPath, $backupRoot, $backupName)
  New-Item -ItemType Directory -Force $backupRoot | Out-Null
  $zip = Join-Path $backupRoot "$backupName.zip"
  if (Test-Path $deployPath) {
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $deployPath "*") -DestinationPath $zip -Force
  } else {
    New-Item -ItemType Directory -Force $deployPath | Out-Null
  }
  return $zip
} @($deployPath, $backupRoot, $backupName) | ForEach-Object { Log "Backup created: $_" }

# 3) Copy payload to remote staging via admin share
$remoteStageLocal = "C:\_gitlab_stage\$siteName"
Log "Preparing remote staging: $remoteStageLocal"
Remote {
  param($stagePath)
  New-Item -ItemType Directory -Force $stagePath | Out-Null
  Remove-Item (Join-Path $stagePath "*") -Recurse -Force -ErrorAction SilentlyContinue
} @($remoteStageLocal)

$remoteStageShare = "\\$hostName\c$\_gitlab_stage\$siteName"
Log "Copying payload to $remoteStageShare"
# /MIR makes it deterministic
robocopy $payload $remoteStageShare /MIR /R:2 /W:2 /NP | Out-Null

# 4) Deploy staging -> deployPath
Log "Deploying to $deployPath"
Remote {
  param($stagePath, $deployPath)
  New-Item -ItemType Directory -Force $deployPath | Out-Null
  robocopy $stagePath $deployPath /MIR /R:2 /W:2 /NP | Out-Null
} @($remoteStageLocal, $deployPath)

# 5) Start IIS
Log "Starting IIS site/app pool..."
Remote {
  param($siteName, $appPoolName)
  Import-Module WebAdministration
  if (Test-Path "IIS:\AppPools\$appPoolName") { Start-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue }
  if (Test-Path "IIS:\Sites\$siteName")       { Start-Website -Name $siteName -ErrorAction SilentlyContinue }
} @($siteName, $appPoolName)

# 6) Health check (optional but recommended)
if ($healthUrl) {
  Log "Health check: $healthUrl"
  try {
    $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 30
    Log "Health OK: HTTP $($resp.StatusCode)"
  }
  catch {
    Log "Health FAILED. Rolling back..."
    Remote {
      param($deployPath, $backupRoot, $backupName, $siteName, $appPoolName)
      Import-Module WebAdministration

      Stop-Website -Name $siteName -ErrorAction SilentlyContinue
      Stop-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue

      $zip = Join-Path $backupRoot "$backupName.zip"
      if (-not (Test-Path $zip)) { throw "Rollback zip not found: $zip" }

      Remove-Item (Join-Path $deployPath "*") -Recurse -Force -ErrorAction SilentlyContinue
      Expand-Archive -Path $zip -DestinationPath $deployPath -Force

      Start-WebAppPool -Name $appPoolName -ErrorAction SilentlyContinue
      Start-Website -Name $siteName -ErrorAction SilentlyContinue
    } @($deployPath, $backupRoot, $backupName, $siteName, $appPoolName)

    throw "Deployment failed health check and was rolled back on $hostName."
  }
} else {
  Log "HEALTH_URL not set; skipping health check."
}

Log "Deployment completed successfully."
