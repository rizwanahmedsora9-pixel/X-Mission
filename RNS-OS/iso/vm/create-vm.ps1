<#
.SYNOPSIS
    Create the RNS-OS virtual machine in Oracle VirtualBox (Windows host).

.DESCRIPTION
    Windows equivalent of create-vm.sh, with the same settings. Creates the
    VM, a 20 GB disk, two network adapters (NAT uplink + customer side) and
    attaches the installer ISO.

    The customer side defaults to a Host-Only adapter so your Windows PC sits
    on the customer network and you can open the captive portal and the staff
    panel from a normal browser to test the whole flow.

    NAT port forwarding is added too, because it works with no network
    configuration at all:
        127.0.0.1:8080 -> guest :8080   staff panel and captive portal
        127.0.0.1:2222 -> guest :22     SSH (root/rnsos until you change it)

.PARAMETER Iso
    Path to RNS-OS-<version>-amd64.iso

.EXAMPLE
    .\create-vm.ps1 -Iso ..\..\dist\RNS-OS-1.0.0-amd64.iso
    .\create-vm.ps1 -Iso FILE -Lan Bridged -BridgeIf "Ethernet"
    .\create-vm.ps1 -Iso FILE -Start
    .\create-vm.ps1 -Iso FILE -NoForward -PanelPort 9090
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [string]$Name = "RNS-OS",
    [int]$SizeMB = 20480,
    [int]$MemoryMB = 2048,
    [int]$Cpus = 2,
    [ValidateSet("HostOnly", "Bridged")][string]$Lan = "HostOnly",
    [string]$BridgeIf = "",
    [string]$HostOnlyIp = "192.168.50.2",
    [int]$PanelPort = 8080,
    [int]$SshPort = 2222,
    [switch]$NoForward,
    [switch]$Start,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Die($msg) { Write-Error "create-vm: $msg"; exit 1 }
function Say($msg) { Write-Host "create-vm: $msg" }

# --- locate VBoxManage ------------------------------------------------------
$VBM = Get-Command VBoxManage -ErrorAction SilentlyContinue
if ($null -eq $VBM) {
    $candidate = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $candidate) { $VBM = $candidate } else { Die "VBoxManage.exe not found - is Oracle VirtualBox installed?" }
} else { $VBM = $VBM.Source }
Say "VBoxManage: $VBM"

function VB {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & $VBM @Args
    if ($LASTEXITCODE -ne 0) { Die "VBoxManage $($Args -join ' ') failed ($LASTEXITCODE)" }
}

if (-not (Test-Path $Iso)) { Die "ISO not found: $Iso" }
$Iso = (Resolve-Path $Iso).Path

# An ISO9660 primary volume descriptor sits at offset 32769. Catching a wrong
# file here beats watching VirtualBox boot into "FATAL: No bootable medium".
$fs = [System.IO.File]::OpenRead($Iso)
try {
    $fs.Seek(32769, [System.IO.SeekOrigin]::Begin) | Out-Null
    $buf = New-Object byte[] 5
    [void]$fs.Read($buf, 0, 5)
    if ([System.Text.Encoding]::ASCII.GetString($buf) -ne "CD001") {
        Die "$Iso is not an ISO9660 image - did you point -Iso at the built RNS-OS ISO?"
    }
} finally { $fs.Close() }
$mb = [math]::Round((Get-Item $Iso).Length / 1MB)
Say "installer ISO ok: $Iso ($mb MB)"

# --- refuse to clobber ------------------------------------------------------
VB showvminfo $Name *> $null 2>&1
if ($LASTEXITCODE -eq 0) {
    if ($Force) {
        Say "removing existing VM $Name (-Force)"
        VB controlvm $Name poweroff *> $null 2>&1
        Start-Sleep -Seconds 2
        VB unregistervm $Name --delete *> $null 2>&1
    } else { Die "a VM named $Name already exists. Use -Force to replace it, or -Name." }
}

# --- customer-side network --------------------------------------------------
$HostOnlyIf = ""
$HostOnlyOk = $false
if ($Lan -eq "HostOnly") {
    $existing = (VB list hostonlyifs) | Select-String '^Name:\s+(.*)$' | Select-Object -First 1
    if ($existing) {
        $HostOnlyIf = $existing.Matches[0].Groups[1].Value.Trim()
    } else {
        Say "creating a host-only network"
        $out = (VB hostonlyif create) 2>&1
        if ($out -match "'(vboxnet\d+)'") { $HostOnlyIf = $Matches[1] } else { $HostOnlyIf = "vboxnet0" }
        VB hostonlyif ipconfig $HostOnlyIf --ip $HostOnlyIp --netmask 255.255.255.0 *> $null 2>&1
        Say "customer side on host-only interface $HostOnlyIf ($HostOnlyIp)"
        $HostOnlyOk = $true
    }
    if (-not $HostOnlyOk) {
        $hIp = ((VB list hostonlyifs) | Select-String '^IPAddress:\s+(.*)$' | Select-Object -First 1)
        $hIp = if ($hIp) { $hIp.Matches[0].Groups[1].Value.Trim() } else { "" }
        Say "customer side on existing host-only interface $HostOnlyIf ($hIp)"
        if ($hIp -like "192.168.50.*") { $HostOnlyOk = $true }
        else {
            Say "  NOTE: $HostOnlyIf is not on the 192.168.50.x subnet the appliance uses,"
            Say "  so this PC cannot browse to the customer side yet. Either move it:"
            Say "      VBoxManage hostonlyif ipconfig $HostOnlyIf --ip $HostOnlyIp --netmask 255.255.255.0"
            Say "  or tell the appliance to use this subnet instead (inside the VM):"
            Say "      rns os config GUEST_IP=<first three octets>.1"
            Say "      systemctl restart rns-net rns-dhcp"
            Say "  The NAT port forwarding below works either way."
        }
    }
} else {
    if (-not $BridgeIf) { Die "-Lan Bridged needs -BridgeIf '<adapter name>'" }
    Say "customer side bridged to $BridgeIf"
}

function Test-PortFree([int]$Port) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}

# --- the VM -----------------------------------------------------------------
Say "creating VM $Name"
VB createvm --name $Name --ostype Debian_64 --register
VB modifyvm $Name `
    --memory $MemoryMB --cpus $Cpus --vram 16 `
    --graphicscontroller vmsvga --accelerate3d off `
    --boot1 dvd --boot2 disk --boot3 none --boot4 none `
    --rtc-use-utc on `
    --nic1 nat --nictype1 82540EM --cableconnected1 on `
    --nic2 $Lan.ToLower() --nictype2 82540EM --cableconnected2 on `
    --usb on --usbehci on

if ($Lan -eq "HostOnly") { VB modifyvm $Name --host-only-adapter2 $HostOnlyIf }
else                     { VB modifyvm $Name --bridge-adapter2 $BridgeIf }

# --- NAT port forwarding: the zero-configuration way in from this PC --------
$PanelHost = $PanelPort
$SshHost = $SshPort
if (-not $NoForward) {
    while (-not (Test-PortFree $PanelHost) -and $PanelHost -lt ($PanelPort + 20)) { $PanelHost++ }
    if ($PanelHost -ne $PanelPort) { Say "host port $PanelPort is in use - using $PanelHost for the panel" }
    while (-not (Test-PortFree $SshHost) -and $SshHost -lt ($SshPort + 20)) { $SshHost++ }
    if ($SshHost -ne $SshPort) { Say "host port $SshPort is in use - using $SshHost for SSH" }
    VB modifyvm $Name --natpf1 "panel,tcp,127.0.0.1,$PanelHost,,8080" --natpf1 "ssh,tcp,127.0.0.1,$SshHost,,22"
}

# --- disk -------------------------------------------------------------------
$MachineFolder = (VB list systemproperties) | Select-String '^Default machine folder:\s+(.*)$'
if ($MachineFolder) { $base = $MachineFolder.Matches[0].Groups[1].Value.Trim() } else { $base = "$env:USERPROFILE\VirtualBox VMs" }
$DiskDir = Join-Path $base $Name
if (-not (Test-Path $DiskDir)) { New-Item -ItemType Directory -Path $DiskDir | Out-Null }
$Disk = Join-Path $DiskDir "$Name.vdi"
if (Test-Path $Disk) { VB closemedium disk $Disk --delete *> $null 2>&1 }

Say "creating ${SizeMB}MB disk"
VB createmedium disk --filename $Disk --size $SizeMB --format VDI
VB storagectl $Name --name SATA --add sata --controller IntelAhci --portcount 2
VB storageattach $Name --storagectl SATA --port 0 --device 0 --type hdd --medium $Disk
VB storageattach $Name --storagectl SATA --port 1 --device 0 --type dvddrive --medium $Iso

Say ""
Say "VM ready: $Name"
Say "  disk    $Disk"
Say "  iso     $Iso"
Say "  uplink  NIC1 nat"
Say "  guests  NIC2 $Lan $HostOnlyIf$BridgeIf"
if (-not $NoForward) {
    Say "  panel   http://127.0.0.1:$PanelHost/admin   (VirtualBox NAT forward)"
    Say "  ssh     ssh -p $SshHost rns@127.0.0.1"
}
Say ""
if ($Start) {
    Say "starting (the installer runs unattended, about 5-10 minutes)"
    VB startvm $Name
} else {
    Say "start it with:  VBoxManage startvm `"$Name`"   (or the VirtualBox GUI)"
}
Say ""
Say "Then:"
Say "  1. the installer partitions the disk and reboots by itself - no keypresses"
Say "  2. log in on the VM console as root / rnsos  (then run: passwd)"
Say "  3. rns os status          what is running, and the portal URL"
if (-not $NoForward) {
    Say "  4. from this PC:  curl.exe -s http://127.0.0.1:$PanelHost/health"
    Say "     then open       http://127.0.0.1:$PanelHost/admin"
}
Say "  Full walkthrough: $PSScriptRoot\VirtualBox.md"
