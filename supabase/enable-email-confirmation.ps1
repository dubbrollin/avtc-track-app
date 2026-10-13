# Turns ON "confirm your email" for new logins on the VYC track app, and points the app's sign-in emails at Resend.
#
# Why: until this is run, anyone can create a password for ANY email address without proving it is theirs.
# After it is run, a new login only works once the person opens the link we email them.
# (Google sign-in is already verified by Google. Logins that already exist keep working.)
#
# Before running: create a Resend account (resend.com), verify the domain you will send from, and create an API key.
# Usage (it asks for the Resend key in a hidden prompt — the key is never shown or saved to a file):
#   powershell -ExecutionPolicy Bypass -File enable-email-confirmation.ps1 -From "messages@your-domain.org"
# To undo: add -Off
param([string]$From, [string]$SenderName = 'VYC Track & Field', [switch]$Off, [string]$Ref = 'qwwmissmsrpfjrsqditi')
$token = $env:SUPABASE_ACCESS_TOKEN
if (-not $token) { $token = [Environment]::GetEnvironmentVariable('SUPABASE_ACCESS_TOKEN', 'User') }
if (-not $token) { throw 'SUPABASE_ACCESS_TOKEN is not set' }
$uri = "https://api.supabase.com/v1/projects/$Ref/config/auth"
if ($Off) {
  $cfg = @{ mailer_autoconfirm = $true }
} else {
  if (-not $From) { throw 'Give the address the emails come from:  -From "messages@your-domain.org"  (the domain must be verified in Resend)' }
  $sec = Read-Host -AsSecureString 'Paste the Resend API key (starts with re_) and press Enter'
  $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  if (-not $key -or -not $key.StartsWith('re_')) { throw 'That does not look like a Resend API key.' }
  $cfg = @{
    mailer_autoconfirm    = $false                 # new logins must open the emailed link
    smtp_host             = 'smtp.resend.com'
    smtp_port             = '465'
    smtp_user             = 'resend'
    smtp_pass             = $key
    smtp_admin_email      = $From
    smtp_sender_name      = $SenderName
    rate_limit_email_sent = 100                    # sign-in emails per hour (the built-in mailer only allowed 2)
    mailer_subjects_confirmation = 'Confirm your email for VYC Track & Field'
    mailer_templates_confirmation_content = '<h2>Confirm it''s you</h2><p>Someone (hopefully you) created a login for VYC Track &amp; Field with this email address.</p><p><a href="{{ .ConfirmationURL }}">Tap here to confirm your email and sign in</a></p><p>If this wasn''t you, ignore this email — no login will be created.</p>'
  }
}
$body = [Text.Encoding]::UTF8.GetBytes(($cfg | ConvertTo-Json -Compress))
$r = Invoke-RestMethod -Method Patch -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json; charset=utf-8' -Body $body
"Email confirmation required for new logins: " + (-not $r.mailer_autoconfirm)
"Sign-in emails sent from: " + $r.smtp_admin_email + "  via " + $r.smtp_host
