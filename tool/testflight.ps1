#Requires -Version 5.1

<#
.SYNOPSIS
  Builds and/or uploads an xcross iOS IPA to TestFlight from Windows.

.DESCRIPTION
  The build uses xcross and the upload uses Apple's official App Store
  Connect Build Upload API. The script never stores or prints the API key.

  A named Windows mutex serializes local runs. The matching GitHub Actions
  example uses concurrency with cancel-in-progress disabled, so queued builds
  wait for the active build instead of cancelling it.

  Node.js is used only to sign the short-lived App Store Connect JWT. The
  private key path is read from an environment variable or parameter and is
  never copied into the repository.

.PARAMETER ProjectPath
  Flutter project directory. Defaults to the current directory.

.PARAMETER IpaPath
  Existing signed IPA to upload. If omitted with -Build, the newest IPA below
  build\xcross-ios is selected after the build.

.PARAMETER Build
  Runs: xcross flutter build ipa --release --ipa --target-platform iphone
  --app-store.

.PARAMETER Upload
  Uploads the selected IPA through the App Store Connect Build Upload API.

.PARAMETER WaitForProcessing
  Polls App Store Connect until the build is VALID or FAILED.

.EXAMPLE
  $env:XCROSS_ASC_ISSUER_ID = '<issuer-uuid>'
  $env:XCROSS_ASC_KEY_ID = '<key-id>'
  $env:XCROSS_ASC_PRIVATE_KEY = 'C:\secrets\AuthKey_<key-id>.p8'
  .\tool\testflight.ps1 -Build -Upload -WaitForProcessing

.EXAMPLE
  .\tool\testflight.ps1 -IpaPath .\build\xcross-ios\MyApp.ipa -Upload
#>

[CmdletBinding()]
param(
  [string]$ProjectPath = (Get-Location).Path,
  [string]$IpaPath,
  [switch]$Build,
  [switch]$Upload,
  [switch]$WaitForProcessing,
  [int]$PollSeconds = 30,
  [int]$TimeoutMinutes = 60,
  [string]$XcrossCommand = 'xcross',
  [string]$AppStoreConnectIssuerId = $env:XCROSS_ASC_ISSUER_ID,
  [string]$AppStoreConnectKeyId = $env:XCROSS_ASC_KEY_ID,
  [string]$AppStoreConnectPrivateKeyPath = $env:XCROSS_ASC_PRIVATE_KEY,
  [string]$AppStoreConnectAppId = $env:XCROSS_ASC_APP_ID
)

$ErrorActionPreference = 'Stop'

function Require-File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label bulunamadı: $Path"
  }
}

function Require-Command {
  param([Parameter(Mandatory = $true)][string]$Name)

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if (!$command) {
    throw "Gerekli komut PATH üzerinde yok: $Name"
  }
  return $command.Source
}

function Get-PlistValue {
  param(
    [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
    [Parameter(Mandatory = $true)][string]$Key
  )

  $keys = $Document.SelectNodes('/plist/dict/key')
  foreach ($keyNode in $keys) {
    if ($keyNode.InnerText -ne $Key) { continue }
    $valueNode = $keyNode.NextSibling
    while ($valueNode -and $valueNode.NodeType -ne [System.Xml.XmlNodeType]::Element) {
      $valueNode = $valueNode.NextSibling
    }
    if ($valueNode) { return $valueNode.InnerText }
  }
  return $null
}

function Read-IpaMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $info = $archive.Entries |
      Where-Object {
        $_.FullName -match '^Payload/[^/]+\.app/Info\.plist$'
      } |
      Select-Object -First 1
    if (!$info) {
      throw 'IPA içinde Payload/<App>.app/Info.plist bulunamadı.'
    }

    $reader = New-Object System.IO.StreamReader($info.Open(), [Text.Encoding]::UTF8)
    try {
      $xmlText = $reader.ReadToEnd()
    } finally {
      $reader.Dispose()
    }

    if ($xmlText -notmatch '<plist') {
      throw 'IPA Info.plist binary formatında. Windows PowerShell uploader XML Info.plist bekliyor.'
    }

    $document = New-Object System.Xml.XmlDocument
    $document.LoadXml($xmlText)
    $bundleId = Get-PlistValue -Document $document -Key 'CFBundleIdentifier'
    $shortVersion = Get-PlistValue -Document $document -Key 'CFBundleShortVersionString'
    $buildVersion = Get-PlistValue -Document $document -Key 'CFBundleVersion'

    foreach ($entry in @{
        BundleId = $bundleId
        ShortVersion = $shortVersion
        BuildVersion = $buildVersion
      }.GetEnumerator()) {
      if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "IPA Info.plist içinde $($entry.Key) eksik."
      }
    }

    return [pscustomobject]@{
      BundleId = $bundleId
      ShortVersion = $shortVersion
      BuildVersion = $buildVersion
    }
  } finally {
    $archive.Dispose()
  }
}

function New-AscJwt {
  param(
    [Parameter(Mandatory = $true)][string]$IssuerId,
    [Parameter(Mandatory = $true)][string]$KeyId,
    [Parameter(Mandatory = $true)][string]$PrivateKeyPath
  )

  $node = Require-Command -Name 'node'
  Require-File -Path $PrivateKeyPath -Label 'App Store Connect private key'

  $script = @'
const crypto = require('crypto');
const fs = require('fs');
function b64(value) {
  return Buffer.from(value).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}
const now = Math.floor(Date.now() / 1000);
const header = b64(JSON.stringify({ alg: 'ES256', kid: process.env.XCROSS_JWT_KEY_ID, typ: 'JWT' }));
const payload = b64(JSON.stringify({
  iss: process.env.XCROSS_JWT_ISSUER_ID,
  iat: now,
  exp: now + 900,
  aud: 'appstoreconnect-v1'
}));
const input = `${header}.${payload}`;
const signature = crypto.sign('sha256', Buffer.from(input), {
  key: fs.readFileSync(process.env.XCROSS_JWT_PRIVATE_KEY),
  dsaEncoding: 'ieee-p1363'
});
process.stdout.write(`${input}.${b64(signature)}`);
'@

  $oldIssuer = $env:XCROSS_JWT_ISSUER_ID
  $oldKeyId = $env:XCROSS_JWT_KEY_ID
  $oldPrivateKey = $env:XCROSS_JWT_PRIVATE_KEY
  try {
    $env:XCROSS_JWT_ISSUER_ID = $IssuerId
    $env:XCROSS_JWT_KEY_ID = $KeyId
    $env:XCROSS_JWT_PRIVATE_KEY = (Resolve-Path -LiteralPath $PrivateKeyPath).Path
    $jwt = & $node -e $script
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jwt)) {
      throw 'App Store Connect JWT üretilemedi.'
    }
    return ($jwt | Out-String).Trim()
  } finally {
    $env:XCROSS_JWT_ISSUER_ID = $oldIssuer
    $env:XCROSS_JWT_KEY_ID = $oldKeyId
    $env:XCROSS_JWT_PRIVATE_KEY = $oldPrivateKey
  }
}

function Get-AscErrorText {
  param([Parameter(Mandatory = $true)]$ErrorRecord)

  try {
    $response = $ErrorRecord.Exception.Response
    if (!$response) { return $ErrorRecord.Exception.Message }
    $stream = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream)
    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($body) { return "HTTP $([int]$response.StatusCode): $body" }
  } catch {
    # Fall through to the original exception when the response is unreadable.
  }
  return $ErrorRecord.Exception.Message
}

function Invoke-AscApi {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Jwt,
    [hashtable]$Body
  )

  $headers = @{
    Authorization = "Bearer $Jwt"
    Accept = 'application/json'
  }
  $params = @{
    Uri = "https://api.appstoreconnect.apple.com/v1$Path"
    Method = $Method
    Headers = $headers
    UseBasicParsing = $true
  }
  if ($Body) {
    $params.ContentType = 'application/json'
    $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
  }

  try {
    return ((Invoke-WebRequest @params).Content | ConvertFrom-Json)
  } catch {
    throw (Get-AscErrorText -ErrorRecord $_)
  }
}

function Convert-UploadHeaders {
  param($Headers)

  $result = @{}
  if ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) { $result[[string]$key] = [string]$Headers[$key] }
  } elseif ($Headers) {
    foreach ($header in @($Headers)) {
      if ($header.name -and $null -ne $header.value) {
        $result[[string]$header.name] = [string]$header.value
      }
    }
  }
  return $result
}

function Read-FileRange {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][Int64]$Offset,
    [Parameter(Mandatory = $true)][Int64]$Length
  )

  if ($Length -gt [Int32]::MaxValue) {
    throw "Apple upload operation is too large for Windows PowerShell: $Length bytes"
  }
  $stream = New-Object System.IO.FileStream(
    $Path,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  try {
    [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $bytes = New-Object byte[] ([int]$Length)
    $read = 0
    while ($read -lt $bytes.Length) {
      $count = $stream.Read($bytes, $read, $bytes.Length - $read)
      if ($count -le 0) { throw 'IPA upload operation file aralığının sonuna ulaştı.' }
      $read += $count
    }
    return $bytes
  } finally {
    $stream.Dispose()
  }
}

function Send-UploadOperation {
  param(
    [Parameter(Mandatory = $true)]$Operation,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][Int64]$FileSize
  )

  $offset = if ($null -eq $Operation.offset) { [Int64]0 } else { [Int64]$Operation.offset }
  $length = if ($null -eq $Operation.length) { $FileSize } else { [Int64]$Operation.length }
  if ($offset -lt 0 -or $length -le 0 -or ($offset + $length) -gt $FileSize) {
    throw "Apple upload operation aralığı geçersiz: offset=$offset length=$length size=$FileSize"
  }

  $bytes = Read-FileRange -Path $Path -Offset $offset -Length $length
  $headers = Convert-UploadHeaders -Headers $Operation.requestHeaders
  $request = [System.Net.WebRequest]::Create([string]$Operation.url)
  $request.Method = if ($Operation.method) { [string]$Operation.method } else { 'PUT' }
  foreach ($name in $headers.Keys) {
    if ($name -ieq 'Content-Length') {
      continue
    }
    if ($name -ieq 'Content-Type') {
      $request.ContentType = $headers[$name]
    } else {
      $request.Headers.Add($name, $headers[$name])
    }
  }
  $request.ContentLength = $bytes.Length
  $body = $request.GetRequestStream()
  try { $body.Write($bytes, 0, $bytes.Length) } finally { $body.Dispose() }
  $response = $request.GetResponse()
  try {
    $status = [int]$response.StatusCode
    if ($status -lt 200 -or $status -ge 300) {
      throw "Apple binary upload failed with HTTP $status"
    }
  } finally {
    $response.Dispose()
  }
}

function Get-BuildUploadState {
  param($Response)
  $attributes = $Response.data.attributes
  $state = $attributes.state
  if ($state -is [string]) { return $state }
  if ($state.state) { return [string]$state.state }
  return $null
}

function Get-IncludedBuildProcessingState {
  param($Response)
  foreach ($item in @($Response.included)) {
    if ($item.type -eq 'builds' -and $item.attributes.processingState) {
      return [string]$item.attributes.processingState
    }
  }
  return $null
}

if (!$Build -and [string]::IsNullOrWhiteSpace($IpaPath)) {
  throw 'En az bir işlem seçin: -Build veya -IpaPath.'
}
if ($Upload -and !$Build -and [string]::IsNullOrWhiteSpace($IpaPath)) {
  throw '-Upload için -IpaPath verin veya -Build kullanın.'
}
if ($PollSeconds -lt 1) { throw '-PollSeconds en az 1 olmalı.' }
if ($TimeoutMinutes -lt 1) { throw '-TimeoutMinutes en az 1 olmalı.' }

$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$mutex = New-Object System.Threading.Mutex($false, 'Local\xcross-TestFlight-Pipeline')
$mutexHeld = $false
$oldLocation = (Get-Location).Path

try {
  Write-Host '=== xcross Windows TestFlight pipeline ==='
  Write-Host "Project: $project"
  Write-Host 'Concurrency: active local run is waited for; cancellation is disabled.'
  try {
    $mutexHeld = $mutex.WaitOne(0)
  } catch [System.Threading.AbandonedMutexException] {
    $mutexHeld = $true
  }
  if (!$mutexHeld) {
    Write-Host 'Another local pipeline is active; waiting for it to finish...'
    try {
      [void]$mutex.WaitOne()
      $mutexHeld = $true
    } catch [System.Threading.AbandonedMutexException] {
      $mutexHeld = $true
    }
  }

  Set-Location $project

  if ($Build) {
    $xcross = Require-Command -Name $XcrossCommand
    Write-Host 'Building App Store IPA with xcross...'
    & $xcross flutter build ipa --release --ipa --target-platform iphone --app-store
    if ($LASTEXITCODE -ne 0) { throw "xcross build başarısız oldu: exit $LASTEXITCODE" }
  }

  if ([string]::IsNullOrWhiteSpace($IpaPath)) {
    $ipa = Get-ChildItem (Join-Path $project 'build\xcross-ios') -Recurse -File -Filter '*.ipa' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if (!$ipa) { throw 'build\xcross-ios altında IPA bulunamadı.' }
    $IpaPath = $ipa.FullName
  } else {
    $IpaPath = (Resolve-Path -LiteralPath $IpaPath).Path
  }
  Require-File -Path $IpaPath -Label 'IPA'

  $metadata = Read-IpaMetadata -Path $IpaPath
  Write-Host "IPA: $IpaPath"
  Write-Host "Bundle: $($metadata.BundleId)"
  Write-Host "Version: $($metadata.ShortVersion) ($($metadata.BuildVersion))"

  if (!$Upload) {
    Write-Host 'Build completed; upload was not requested.'
    return
  }

  if ([string]::IsNullOrWhiteSpace($AppStoreConnectIssuerId) -or
      [string]::IsNullOrWhiteSpace($AppStoreConnectKeyId) -or
      [string]::IsNullOrWhiteSpace($AppStoreConnectPrivateKeyPath)) {
    throw 'ASC bilgileri eksik. XCROSS_ASC_ISSUER_ID, XCROSS_ASC_KEY_ID ve XCROSS_ASC_PRIVATE_KEY ayarlayın.'
  }

  $jwt = New-AscJwt `
    -IssuerId $AppStoreConnectIssuerId `
    -KeyId $AppStoreConnectKeyId `
    -PrivateKeyPath $AppStoreConnectPrivateKeyPath

  $appId = $AppStoreConnectAppId
  if ([string]::IsNullOrWhiteSpace($appId)) {
    $appQuery = [Uri]::EscapeDataString($metadata.BundleId)
    $apps = Invoke-AscApi -Method GET -Path "/apps?filter[bundleId]=$appQuery&limit=200" -Jwt $jwt
    $matches = @($apps.data | Where-Object { $_.attributes.bundleId -eq $metadata.BundleId })
    if ($matches.Count -ne 1) {
      throw "Bundle ID için App Store Connect'te tek bir app bulunamadı: $($metadata.BundleId)"
    }
    $appId = [string]$matches[0].id
  }
  Write-Host "App Store Connect app id: $appId"

  $upload = Invoke-AscApi -Method POST -Path '/buildUploads' -Jwt $jwt -Body @{
    data = @{
      type = 'buildUploads'
      attributes = @{
        cfBundleShortVersionString = $metadata.ShortVersion
        cfBundleVersion = $metadata.BuildVersion
        platform = 'IOS'
      }
      relationships = @{
        app = @{ data = @{ type = 'apps'; id = $appId } }
      }
    }
  }
  $uploadId = [string]$upload.data.id
  Write-Host "Build upload reservation: $uploadId"

  $ipaItem = Get-Item -LiteralPath $IpaPath
  $fileReservation = Invoke-AscApi -Method POST -Path '/buildUploadFiles' -Jwt $jwt -Body @{
    data = @{
      type = 'buildUploadFiles'
      attributes = @{
        assetType = 'ASSET'
        fileName = $ipaItem.Name
        fileSize = [Int64]$ipaItem.Length
        uti = 'com.apple.ipa'
      }
      relationships = @{
        buildUpload = @{ data = @{ type = 'buildUploads'; id = $uploadId } }
      }
    }
  }
  $fileId = [string]$fileReservation.data.id
  $operations = @($fileReservation.data.attributes.uploadOperations)
  if ($operations.Count -eq 0) { throw 'Apple upload operation döndürmedi.' }

  Write-Host "Uploading IPA ($($ipaItem.Length) bytes, $($operations.Count) operation)..."
  foreach ($operation in $operations) {
    Send-UploadOperation -Operation $operation -Path $IpaPath -FileSize ([Int64]$ipaItem.Length)
  }

  $md5 = (Get-FileHash -LiteralPath $IpaPath -Algorithm MD5).Hash.ToLowerInvariant()
  [void](Invoke-AscApi -Method PATCH -Path "/buildUploadFiles/$fileId" -Jwt $jwt -Body @{
    data = @{
      type = 'buildUploadFiles'
      id = $fileId
      attributes = @{ uploaded = $true; sourceFileChecksum = $md5 }
    }
  })
  Write-Host 'Binary upload committed to App Store Connect.'

  if ($WaitForProcessing) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
      Start-Sleep -Seconds $PollSeconds
      $status = Invoke-AscApi `
        -Method GET `
        -Path "/buildUploads/$uploadId?include=build" `
        -Jwt $jwt
      $uploadState = Get-BuildUploadState -Response $status
      $processingState = Get-IncludedBuildProcessingState -Response $status
      Write-Host "Status: upload=$uploadState build=$processingState"

      if ($uploadState -eq 'FAILED' -or $processingState -eq 'INVALID') {
        throw 'App Store Connect build processing failed. Ayrıntı için App Store Connect Build Uploads ekranını açın.'
      }
      if ($processingState -eq 'VALID' -or
          ($uploadState -eq 'COMPLETE' -and !$processingState)) {
        Write-Host 'TestFlight processing: VALID'
        break
      }
      if ((Get-Date) -ge $deadline) {
        throw "Build processing $TimeoutMinutes dakika içinde tamamlanmadı. Upload ID: $uploadId"
      }
    } while ($true)
  }

  Write-Host 'TESTFLIGHT PIPELINE PASS'
} finally {
  Set-Location $oldLocation
  if ($mutexHeld) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
