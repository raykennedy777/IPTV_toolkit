# Copy this file to IPTVConfigs.ps1 and fill in your provider details.
# IPTVConfigs.ps1 is gitignored so your credentials stay local.

# Path to PowerShell 7 executable (used when scheduling via Task Scheduler)
$Global:pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"

$Global:IPTVConfigs = @{

    # Each key is a config name you pass with -Config (e.g. -Config myprovider)
    myprovider = @{
        Username   = "your_username"
        Password   = "your_password"

        # Base URL for live streams (without trailing slash)
        BaseUrl    = "http://your.provider.url/live"

        # URL for catch-up/timeshift requests
        CatchupUrl = "http://your.provider.url/streaming/timeshift.php"

        # Set to $true if live stream URLs should end in .ts
        AddTsSuffix = $false

        # How the catch-up URL is constructed:
        #   "query" -> CatchupUrl?username=...&password=...&stream=ID&start=TIME&duration=SECS
        #   "path"  -> BaseUrl/timeshift/username/password/SECS/TIME/ID.ts
        CatchupFormatStyle = "query"

        # Map of friendly channel names to stream IDs from your provider
        ChannelMap = @{
            "channel_name_1" = "stream_id_1"
            "channel_name_2" = "stream_id_2"
        }
    }

    # Add more provider configs here, e.g.:
    # anotherprovider = @{
    #     Username           = "..."
    #     Password           = "..."
    #     BaseUrl            = "http://..."
    #     CatchupUrl         = "http://..."
    #     AddTsSuffix        = $true
    #     CatchupFormatStyle = "path"
    #     ChannelMap         = @{ ... }
    # }
}
