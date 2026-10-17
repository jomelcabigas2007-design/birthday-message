$ErrorActionPreference = "Stop"
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$rootPrefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8080/")

$contentTypes = @{
    ".css"  = "text/css; charset=utf-8"
    ".html" = "text/html; charset=utf-8"
    ".ico"  = "image/x-icon"
    ".js"   = "text/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".mp4"  = "video/mp4"
    ".png"  = "image/png"
    ".svg"  = "image/svg+xml"
    ".txt"  = "text/plain; charset=utf-8"
}

function Send-TextResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$Text,
        [string]$Method
    )

    $body = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "text/plain; charset=utf-8"
    $Context.Response.ContentLength64 = $body.Length
    if ($Method -ne "HEAD") {
        $Context.Response.OutputStream.Write($body, 0, $body.Length)
    }
}

$listener.Start()
Write-Output "Birthday site listening at http://localhost:8080/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $method = $request.HttpMethod

        try {
            if ($method -ne "GET" -and $method -ne "HEAD") {
                $response.Headers["Allow"] = "GET, HEAD"
                Send-TextResponse -Context $context -StatusCode 405 -Text "Method not allowed" -Method $method
                continue
            }

            $relativePath = [System.Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart("/"))
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                $relativePath = "index.html"
            }

            $filePath = [System.IO.Path]::GetFullPath((Join-Path $root $relativePath))
            if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-TextResponse -Context $context -StatusCode 403 -Text "Forbidden" -Method $method
                continue
            }

            if ([System.IO.Directory]::Exists($filePath)) {
                $filePath = [System.IO.Path]::GetFullPath((Join-Path $filePath "index.html"))
            }

            if (-not [System.IO.File]::Exists($filePath)) {
                Send-TextResponse -Context $context -StatusCode 404 -Text "Not found" -Method $method
                continue
            }

            $fileInfo = New-Object System.IO.FileInfo($filePath)
            $length = [long]$fileInfo.Length
            $start = [long]0
            $end = $length - 1
            $rangeHeader = $request.Headers["Range"]

            if ($rangeHeader) {
                $rangeMatch = [regex]::Match($rangeHeader, "^bytes=(\d*)-(\d*)$")
                if (-not $rangeMatch.Success -or $length -eq 0) {
                    $response.StatusCode = 416
                    $response.Headers["Content-Range"] = "bytes */$length"
                    $response.ContentLength64 = 0
                    continue
                }

                if ($rangeMatch.Groups[1].Value -eq "") {
                    $suffixLength = [long]$rangeMatch.Groups[2].Value
                    if ($suffixLength -le 0) {
                        $response.StatusCode = 416
                        $response.Headers["Content-Range"] = "bytes */$length"
                        $response.ContentLength64 = 0
                        continue
                    }
                    $start = [Math]::Max([long]0, $length - $suffixLength)
                }
                else {
                    $start = [long]$rangeMatch.Groups[1].Value
                    if ($rangeMatch.Groups[2].Value -ne "") {
                        $end = [long]$rangeMatch.Groups[2].Value
                    }
                }

                if ($start -ge $length -or $end -lt $start) {
                    $response.StatusCode = 416
                    $response.Headers["Content-Range"] = "bytes */$length"
                    $response.ContentLength64 = 0
                    continue
                }

                $end = [Math]::Min($end, $length - 1)
                $response.StatusCode = 206
                $response.Headers["Content-Range"] = "bytes $start-$end/$length"
            }

            $extension = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
            if ($contentTypes.ContainsKey($extension)) {
                $response.ContentType = $contentTypes[$extension]
            }
            else {
                $response.ContentType = "application/octet-stream"
            }
            $response.Headers["Accept-Ranges"] = "bytes"
            $response.ContentLength64 = $end - $start + 1

            if ($method -eq "GET") {
                $stream = [System.IO.File]::OpenRead($filePath)
                try {
                    $stream.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $buffer = New-Object byte[] 65536
                    $remaining = $end - $start + 1
                    while ($remaining -gt 0) {
                        $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                        if ($read -eq 0) {
                            break
                        }
                        $response.OutputStream.Write($buffer, 0, $read)
                        $remaining -= $read
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
        }
        catch {
            Write-Warning "Request failed for $($request.Url.AbsolutePath): $($_.Exception.Message)"
            try {
                $response.StatusCode = 500
                $response.ContentLength64 = 0
            }
            catch {
                Write-Warning "Could not send an error response: $($_.Exception.Message)"
            }
        }
        finally {
            $response.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Output "Birthday site stopped."
}
