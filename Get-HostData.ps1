<#
.SYNOPSIS
A reference script for collecting data from hosts in an organization when seining for evil.
What does the script collect:
  1. Prefetch
  2. Processes using Powershell Get-Process (includes modules, threads, etc.)
  3. Processes using tasklist (includes owner)
  4. Open handles using Sysinternals Handle.exe
  5. DNS cache
  6. ARP cache
  7. Netstat with process name and PID
  8. Autoruns using Sysinternals Autorunsc.exe
  9. Bits Transfers
 10. Service Triggers
 11. Service failures
 12. WMI Event Consumers
 13. Powershell profiles
  
All output is copied to a zip archive for offline analysis.

I have run this script or slight variations of it over 10s of 1000s of hosts at a time and performed analysis beginning
with stack ranking the data (see https://github.com/davehull/Get-StakRank#get-stakrank) and reviewing outliers. There 
are commercial products that will gather much of this data, and in more robust ways, bypassing the WinAPI and scraping
memory for process and networking artifacts, but those tools can take hours to run depending on the amount of RAM in 
the box. This script takes a couple minutes per host.

Average size of collected data is around 1.5 - 2 MiB with compression. Uncompressed data averages around 10 - 12MiB per
host, but YMMV depending on what your hosts are doing.
#>

$sharename = "\\CONFIGURE\THIS"
# $sharename = ".\"
# make a \bin\ dir in the share for latest version of Sysinternals autorunsc.exe and handle.exe 
# available from http://technet.microsoft.com/en-us/sysinternals


if ($sharename -match "CONFIGURE") {
    Write-Host "`n[*] ERROR: You must edit the script and configure a share for the data to be written to, and for autorunsc.exe to be run from.`n"
    Exit
}

#put autorunsc.exe, handle.exe in the following path
$sharebin = $sharename + "\bin\"

$temp = $env:temp
$this_computer = $($env:COMPUTERNAME)
$zipfile = $temp + "\" + $this_computer + "_bh.zip"
$ErrorLog = $temp + "\" + $this_computer + "_error.log"


# get prefetch listing
$pfconf = (gp "hklm:\system\currentcontrolset\control\session manager\memory management\prefetchparameters").EnablePrefetcher 
Switch -Regex ($pfconf) {
    "[1-3]" {
        $pffiles = $temp + "\" + $this_computer + "_pffiles.txt"
        ls $env:windir\Prefetch\*.pf | Set-Content -Encoding Ascii $pffiles
    }
    default { }
}

# get process data
$procout = $temp + "\" + $this_computer + "_prox.xml"
Get-Process | Export-Clixml $procout

# tasklist gives username
$tlist = $temp + "\" + $this_computer + "_tlist.csv"
& tasklist.exe /v /fo csv | Set-Content -Encoding Ascii $tlist

# get handle
$handleout = $temp + "\" + $this_computer + "_handle.txt"
& "$sharebin\handle.exe" /accepteula -a | Set-Content -Encoding Ascii $handleout

# get dnscache
$dnsout = $temp + "\" + $this_computer + "_dnscache.txt"
& ipconfig.exe /displaydns | Select-String 'Record Name' | ForEach-Object { $_.ToString().Split(' ')[-1] } | `
  select -Unique | sort | Set-Content -Encoding Ascii $dnsout

# get arp cache
$arpout = $temp + "\" + $this_computer + "_arp.txt"
& ARP.EXE -a | Set-Content -Encoding Ascii $arpout

# get netstat
$netstatout = $temp + "\" + $this_computer + "_netstat.txt"
& NETSTAT.EXE -n -a -o -b | Set-Content -Encoding Ascii $netstatout

# get autoruns
$arunsout = $temp + "\" + $this_computer + "_aruns.csv"
& "$sharebin\autorunsc.exe" /accepteula -a -c -v -f '*' | Set-Content -Encoding Ascii $arunsout

# get bits transfers
$bitsxferout = $temp + "\" + $this_computer + "_bitsxfer.xml"
Get-BitsTransfer -AllUsers | Export-Clixml $bitsxferout

# get service triggers
$svctrigout = $temp + "\" + $this_computer + "_svctriggers.txt"
$($(foreach ($svc in (& c:\windows\system32\sc query)) { 
  if ($svc -match "SERVICE_NAME:\s(.*)") {
    & c:\windows\system32\sc qtriggerinfo $($matches[1])
  }
})|?{$_.length -gt 1 -and $_ -notmatch "\[SC\] QueryServiceConfig2 SUCCESS|has not registered for any" }) | Set-Content -Encoding Ascii $svctrigout

# get service failure
$svcfailout = $temp + "\" + $this_computer + "_svcfailout.txt"
$($(foreach ($svc in (& c:\windows\system32\sc query)) { 
    if ($svc -match "SERVICE_NAME:\s(.*)") { 
        & c:\windows\system32\sc qfailure $($matches[1])}})) | Set-Content -Encoding Ascii $svcfailout

# get wmi event consumers
$wmievtconsmr = $temp + "\" + $this_computer + "_wmievtconsmr.xml"
Get-WmiObject -Namespace root\subscription -ComputerName $this_computer -Query "select * from __EventConsumer" | Export-Clixml $wmievtconsmr

$wmievtfilter = $temp + "\" + $this_computer + "_wmievtfilter.xml"
Get-WmiObject -Namespace root\subscription -ComputerName $this_computer -Query "select * from __EventFilter" | Export-Clixml $wmievtfilter

$wmievtfltbind = $temp + "\" + $this_computer + "_wmievtfltbind.xml"
Get-WmiObject -Namespace root\subscription -ComputerName $this_computer -Query "select * from __FilterToConsumerBinding" | Export-Clixml $wmievtfltbind

# get powershell profiles
$alluserprofile = ($env:windir + "\System32\WindowsPowershell\v1.0\Microsoft.Powershell_profile.ps1")
if (Test-Path $alluserprofile) {
    $psalluserprofile = $temp + "\" + $this_computer + "_alluserprofile.txt"
    gc $alluserprofile | Set-Content -Encoding Ascii $psalluserprofile
}

$psuserprofiles = $temp + "\" + $this_computer + "_userprofiles.txt"
$null | Set-Content -Encoding Ascii $psuserprofiles
foreach($path in (gwmi win32_userprofile | select localpath -ExpandProperty localpath)) {
    $prfile = ($path + "\Documents\WindowsPowershell\Microsoft.Powershell_profile.ps1")
    if (Test-Path $prfile) {
        $("Profile ${prfile}:"; gc $prfile) | Add-Content -Encoding Ascii $psuserprofiles
    }
}


# check for locked files
function Test-FileLock {
    param([parameter(Mandatory=$true)]
        [string]$Path
    )

    $oFile = New-Object System.IO.FileInfo $Path

    if ((Test-Path -Path $Path) -eq $false)
    {
        $false 
        return
    }

    try {
        $oStream = $oFile.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($oStream) {
            $oStream.Close()
        }
        $false
    }
    catch {
        $true
    }
}


# consolidate all
function add-zip
{
    param([string]$zipfilename)

    if (-not (Test-Path($zipfilename))) {
        Set-Content $zipfilename ("PK" + [char]5 + [char]6 + ("$([char]0)" * 18))
        (dir $zipfilename).IsReadOnly = $false
    }

    $shellApplication = New-Object -com shell.application
    $zipPackage = $shellApplication.NameSpace($zipfilename)

    foreach($file in $input) {
        $zipPackage.CopyHere($file.FullName)
        Start-Sleep -milliseconds 500
    }
}

# wait for locked zipfile
function ziplock
{
    param([string]$zipfilename)
    $tries = 0
    while ($tries -lt 100) {
        if (Test-FileLock($zipfile)) {
            Start-Sleep -seconds 1
            $tries++
            continue
        } else {
            break
        }
    }
}

try {
    if (Test-Path $dnsout -ErrorAction SilentlyContinue) {
        ls $dnsout     | add-zip $zipfile
        Write-Verbose "`$dnsout added"
        ziplock $zipfile
        rm $dnsout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $procout -ErrorAction SilentlyContinue) {
        ls $procout    | add-zip $zipfile
        Write-Verbose "`$procout added"
        ziplock $zipfile
        rm $procout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $tlist -ErrorAction SilentlyContinue) {
        ls $tlist      | add-zip $zipfile
        Write-Verbose "`$tlist added"
        ziplock $zipfile
        rm $tlist
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $arpout -ErrorAction SilentlyContinue) {
        ls $arpout     | add-zip $zipfile
        Write-Verbose "`$arpout added"
        ziplock $zipfile
        rm $arpout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $netstatout -ErrorAction SilentlyContinue) {
        ls $netstatout | add-zip $zipfile
        Write-Verbose "`$netstatout added"
        ziplock $zipfile
        rm $netstatout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $arunsout -ErrorAction SilentlyContinue) {
        ls $arunsout   | add-zip $zipfile
        Write-Verbose "`$arunsout added"
        ziplock $zipfile
        rm $arunsout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $handleout -ErrorAction SilentlyContinue) {
        ls $handleout  | add-zip $zipfile
        Write-Verbose "`$handleout added"
        ziplock $zipfile
        rm $handleout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $bitsxferout -ErrorAction SilentlyContinue) {
        ls $bitsxferout | add-zip $zipfile
        Write-Verbose "`$bitsxferout added"
        ziplock $zipfile
        rm $bitsxferout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $svctrigout -ErrorAction SilentlyContinue) {
        ls $svctrigout | add-zip $zipfile
        Write-Verbose "`$svctrigout added"
        ziplock $zipfile
        rm $svctrigout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $svcfailout -ErrorAction SilentlyContinue) {
        ls $svcfailout | add-zip $zipfile
        Write-Verbose "`$svcfailout added"
        ziplock $zipfile
        rm $svcfailout
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $wmievtconsmr -ErrorAction SilentlyContinue) {
        ls $wmievtconsmr | add-zip $zipfile
        Write-Verbose "`$wmievtconsmr added"
        ziplock $zipfile
        rm $wmievtconsmr
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $psalluserprofile -ErrorAction SilentlyContinue) {
        ls $psalluserprofile | add-zip $zipfile
        Write-Verbose "`$psalluserprofile added"
        ziplock $zipfile
        rm $psalluserprofile
    }
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-Path $psuserprofiles -ErrorAction SilentlyContinue) {
        ls $psuserprofiles | add-zip $zipfile
        Write-Verbose "`$psuserprofiles added"
        ziplock $zipfile
        rm $psuserprofiles
    } 
} catch { 
    $_.Exception.Message | Add-Content $ErrorLog
}

try {
    if (Test-path $pffiles -ErrorAction SilentlyContinue) {
        ls $pffiles | add-zip $zipfile
        Write-Verbose "`$pffiles added"
        ziplock $zipfile
        rm $pffiles
    }
} catch {
    $_.Exception.Message | Add-Content $ErrorLog
}

copy $zipfile $sharename

ls $ErrorLog | add-zip $zipfile
ziplock $zipfile        
rm $zipfile