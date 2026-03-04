$ErrorActionPreference = "Stop"

# Workspace
$workRoot = Join-Path $PSScriptRoot "..\work"
$payload  = Join-Path $workRoot "payload"
$meta     = Join-Path $workRoot "meta"
New-Item -ItemType Directory -Force $payload | Out-Null
New-Item -ItemType Directory -Force $meta | Out-Null

$logFile = Join-Path $meta ("prepare-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

function Log($msg) {
  $line = "$(Get-Date -Format o) [PREPARE] $msg"
  $line | Tee-Object -FilePath $logFile -Append
}

# Inputs
$artifactUrl = $env:ARTIFACT_URL
$artiUser    = $env:ARTIFACTORY_USER
$artiPass    = $env:ARTIFACTORY_PASSWORD

if (-not $artifactUrl) { throw "ARTIFACT_URL is required." }
if (-not $artiUser -or -not $artiPass) { throw "ARTIFACTORY_USER/ARTIFACTORY_PASSWORD required." }

$zipPath = Join-Path $meta "app.zip"

# Clean payload folder
Remove-Item (Join-Path $payload "*") -Recurse -Force -ErrorAction SilentlyContinue

Log "Downloading package from Artifactory..."
# Use curl.exe on Windows
& curl.exe -f -L -u "$artiUser`:$artiPass" -o "$zipPath" "$artifactUrl"
Log "Downloaded: $zipPath"

Log "Extracting ZIP..."
Expand-Archive -Path $zipPath -DestinationPath $payload -Force

# Find web.config (handles packages where it is not at root)
Log "Locating web.config inside payload..."
$configFile = Get-ChildItem -Path $payload -Recurse -Filter "web.config" | Select-Object -First 1
if (-not $configFile) { throw "web.config not found inside extracted package." }

Log "Using web.config path: $($configFile.FullName)"

# Load XML
[xml]$xml = Get-Content $configFile.FullName

# Replace appSettings based on env var names == key
if ($xml.configuration.appSettings -and $xml.configuration.appSettings.add) {
  foreach ($node in $xml.configuration.appSettings.add) {
    $keyName = $node.key
    if ($keyName) {
      $ciValue = [Environment]::GetEnvironmentVariable($keyName)
      if ($ciValue) {
        Log "Updating appSetting key='$keyName' (value from CI variable)."
        $node.value = $ciValue
      }
    }
  }
}

# Replace connectionStrings based on env var names == name
if ($xml.configuration.connectionStrings -and $xml.configuration.connectionStrings.add) {
  foreach ($conn in $xml.configuration.connectionStrings.add) {
    $name = $conn.name
    if ($name) {
      $ciValue = [Environment]::GetEnvironmentVariable($name)
      if ($ciValue) {
        Log "Updating connectionString name='$name' (value from CI variable)."
        $conn.connectionString = $ciValue
      }
    }
  }
}

# Save updated config back into payload
$xml.Save($configFile.FullName)
Log "web.config updated successfully."

# Optional: store a small metadata file (no secrets)
$metaJson = @{
  artifact_url = $artifactUrl
  prepared_at  = (Get-Date).ToString("o")
  web_config   = $configFile.FullName.Replace($payload, "payload")
  commit       = $env:CI_COMMIT_SHA
  tag          = $env:CI_COMMIT_TAG
  branch       = $env:CI_COMMIT_BRANCH
} | ConvertTo-Json -Depth 5

Set-Content -Path (Join-Path $meta "prepare-meta.json") -Value $metaJson -Encoding UTF8
Log "Prepare stage complete."
