param([Parameter(Mandatory)][uri]$Origin)
# Callback-safe negative probe only. No signature means no queue/receipt/consumer work.
$uri=[uri]::new($Origin,'/api/discordrelay')
if($uri.Scheme -ne 'https' -and !$uri.IsLoopback){throw 'Require HTTPS or loopback'}
$response=Invoke-WebRequest -Uri $uri -Method Post -ContentType 'application/json' -Body '{"type":1}' -SkipHttpErrorCheck
if([int]$response.StatusCode -ne 401){throw "Expected unsigned401; observed $($response.StatusCode)"}
Write-Output 'PASS unsigned Discord request rejected; genuine signed ping and queue/callback acceptance remain separate.'