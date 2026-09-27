# Runs SQL against the live VYC Supabase database via the Management API.
# Usage: .\supabase\run-sql.ps1 -Sql "select 1"   or   -File path\to\file.sql
# Needs the SUPABASE_ACCESS_TOKEN user environment variable (Supabase account access token).
param([string]$Sql, [string]$File, [string]$Ref = 'qwwmissmsrpfjrsqditi')
if ($File) { $Sql = Get-Content $File -Raw }
if (-not $Sql) { throw 'Provide -Sql or -File' }
$token = $env:SUPABASE_ACCESS_TOKEN
if (-not $token) { $token = [Environment]::GetEnvironmentVariable('SUPABASE_ACCESS_TOKEN', 'User') }
if (-not $token) { throw 'SUPABASE_ACCESS_TOKEN is not set' }
$body = @{ query = $Sql } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Post -Uri "https://api.supabase.com/v1/projects/$Ref/database/query" `
  -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body
