$url = "https://discord.relay.sda.studio/api/discord?"
#$url = "https://feeds.sda.studio/api/GetCurrentMedia"
#$url = "http://localhost:7107/api/discord"

#$origin = "https://localhost:7107"

$Body = "test"

# Create an Invoke-WebRequest with a custom Origin header
$response = Invoke-WebRequest -Uri $url -Method Post -Body $Body -ErrorAction Stop

# Display the response status code and Access-Control-Allow-Origin header
Write-Output "Response Status Code: $($response.StatusCode)"
if ($response.Headers["Access-Control-Allow-Origin"]) {
    Write-Output "Access-Control-Allow-Origin: $($response.Headers["Access-Control-Allow-Origin"])"
} else {
    Write-Output "Access-Control-Allow-Origin header not found"
}

$reponse


