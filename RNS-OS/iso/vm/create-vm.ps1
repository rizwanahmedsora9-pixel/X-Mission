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

.PARAMETER Iso
    Path to RNS-OS-<version>-amd64.iso

.EXAMPLE
    .\create-vm.ps1 -Iso ..\..\dist\RNS-OS-1.0.0-amd64.iso
    .\create-vm.ps1 -Iso FILE -Lan Bridged -BridgeIf "Ethernet"
    .\create-vm.ps1 -Iso FILE -Start
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
if ($Lan -eq "HostOnly") {
    $existing = (VB list hostonlyifs) | Select-String '^Name:\s+(.*)$' | Select-Object -First 1
    if ($existing) {
        $HostOnlyIf = $existing.Matches[0].Groups[1].Value.Trim()
    } else {
        Say "creating a host-only network"
        $out = (VB hostonlyif create) 2>&1
        if ($out -match "'(vboxnet\d+)'") { $HostOnlyIf = $Matches[1] } else { $HostOnlyIf = "vboxnet0" }
        VB hostonlyif ipconfig $HostOnlyIf --ip 192.168.56.1 --netmask 255.255.255.0 *> $null 2>&1
    }
    Say "customer side on host-only interface $HostOnlyIf"
} else {
    if (-not $BridgeIf) { Die "-Lan Bridged needs -BridgeIf '<adapter name>'" }
    Say "customer side bridged to $BridgeIf"
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
Say ""
if ($Start) {
    Say "starting (the installer runs unattended, about 5-10 minutes)"
    VB startvm $Name
} else {
    Say "start it with:  VBoxManage startvm `"$Name`"   (or the VirtualBox GUI)"
}
Say ""
Say "When it reboots into RNS-OS, log in as root/rnsos (CHANGE IT: passwd) and run"
Say "  rns os status        then open the staff panel URL it prints."
