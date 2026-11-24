$ErrorActionPreference='Stop'
$platform=if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){'Linux'}
elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){'Windows'}else{'Other'}
[pscustomobject]@{platform=$platform;os=[Runtime.InteropServices.RuntimeInformation]::OSDescription}
