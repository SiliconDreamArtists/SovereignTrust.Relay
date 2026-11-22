param([Parameter(Mandatory)][string]$PublishDirectory,[Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'Host evidence output must be new'}
New-Item -ItemType Directory -Path $EvidenceDirectory|Out-Null
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start(); $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
$start=[Diagnostics.ProcessStartInfo]::new('dotnet')
$start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.CreateNoWindow=$true
$start.ArgumentList.Add((Join-Path (Resolve-Path $PublishDirectory).Path 'SovereignTrust.Relay.Azure.dll'))
$start.ArgumentList.Add('--urls');$start.ArgumentList.Add("http://127.0.0.1:$port")
$start.Environment['DISCORD_PUBLIC_KEY']='d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'
$start.Environment['StorageQueueAccount']='UseDevelopmentStorage=true'
$start.Environment['ENABLE_ED25519_SIGNING']='false'
$process=[Diagnostics.Process]::Start($start)
$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
$client=[Net.Http.HttpClient]::new();$client.Timeout=[TimeSpan]::FromSeconds(1)
try {
    $ready=$false;$deadline=[DateTime]::UtcNow.AddSeconds(15)
    while([DateTime]::UtcNow -lt $deadline -and !$process.HasExited){
        try{$response=$client.GetAsync("http://127.0.0.1:$port/healthz").GetAwaiter().GetResult();$ready=$response.IsSuccessStatusCode;$response.Dispose()}catch{}
        if($ready){break};Start-Sleep -Milliseconds 100
    }
    if(!$ready){throw 'Published Kestrel did not become healthy'}
    $bad=$client.PostAsync("http://127.0.0.1:$port/api/discordrelay",[Net.Http.StringContent]::new('{}')).GetAwaiter().GetResult()
    if([int]$bad.StatusCode -ne 401){throw 'Published unsigned request not rejected'};$bad.Dispose()
    foreach($path in @('/api/GenerateEd25519KeyPair','/api/Ed25519SignFunction')){
        $request=[Net.Http.HttpRequestMessage]::new($(if($path -like '*SignFunction'){[Net.Http.HttpMethod]::Post}else{[Net.Http.HttpMethod]::Get}),"http://127.0.0.1:$port$path")
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 404){throw 'Published helper enabled'};$response.Dispose();$request.Dispose()
    }
    Write-Output 'PASS published Kestrel health/unsigned401/helpers404; no queue or callback invoked'
}finally{
    $client.Dispose()
    if(!$process.HasExited){$process.Kill($true)};$process.WaitForExit()
    [IO.File]::WriteAllText((Join-Path (Resolve-Path $EvidenceDirectory) 'stdout.log'),$stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path (Resolve-Path $EvidenceDirectory) 'stderr.log'),$stderr.GetAwaiter().GetResult())
    $process.Dispose()
}
