# Author: Sean Wilkie
# Description: Script to add new VMDKs w/the MultiWriter Flag enabled in vSphere 6.x and connect them to two Oracle RAC Nodes
# finds the 2nd and 3rd ORAC nodes by incrementing the number at the end of $MasterNode
# Reference: http://www.virtuallyghetto.com/2015/10/new-method-of-enabling-multiwriter-vmdk-flag-in-vsphere-6-0-update-1.html

param (
    [Parameter()]
    #[ValidateNotNullOrEmpty()]
    [string]$MasterNode,

    [Parameter()]
    [string]
    $DataStore,

    [Parameter()]
    [string]
    $vcname,

    [Parameter()]
    [string]z
    $vcuser,

    [Parameter()]
    [string]
    $vcpass

    # [Parameter]
    # [switch]
    # $addNodes
)


function IncrementNodeNumber {
    param ($node)

    #Write-Host $node
    $CurrLen = $node.Length - 1
    $CurrNum = $node.Substring($CurrLen)
    $NextNum = [int]$CurrNum + 1

    $NextName = $node.SubString(0,$CurrLen) + $NextNum
    
    return $NextName
}

#####################
####### Vars ########

$vcname = "" #Insert vCenter URL here
#$vcuser = ""
#$vcpass = ""

$VMDataStore = $DataStore + " "

#$vmName = $MasterNode
$vmName = $MasterNode
#write-host $vmName
Write-Host "MasterNode: " $vmName
$date = (get-date).ToString()

# Use (Get-VM -Name "Multi-Writer-VM").ExtensionData.Layout.Disk to help identify VM-Home-Dir

# Hashtable to create Oracle RAC VMDK's
$VMData = @{
    "Name" = $vmName
    "dataStore" = $VMDataStore
    "SCSI" = $diskControllerNumber
    "date" = $date
    "disks" = @(
        @{"name" = $VMDataStore + $vmName + "/multiwriter-01" + ".vmdk"; "size" = 25; "diskNum" = 0},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-02" + ".vmdk"; "size" = 25; "diskNum" = 1},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-03" + ".vmdk"; "size" = 25; "diskNum" = 2},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-04" + ".vmdk"; "size" = 50; "diskNum" = 3},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-05" + ".vmdk"; "size" = 50; "diskNum" = 4},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-06" + ".vmdk"; "size" = 20; "diskNum" = 5},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-07" + ".vmdk"; "size" = 20; "diskNum" = 6},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-08" + ".vmdk"; "size" = 20; "diskNum" = 8},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-09" + ".vmdk"; "size" = 20; "diskNum" = 9},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-10" + ".vmdk"; "size" = 20; "diskNum" = 10},
        @{"name" = $VMDataStore + $vmName + "/multiwriter-11" + ".vmdk"; "size" = 20; "diskNum" = 11}
    )
}

#$VMData | ConvertTo-Json | Out-File ".\VMData.json"

$diskControllerNumber = 1

#######################################
######### Beginning of Script #########
$server = Connect-VIServer -Server $vcname -User $vcuser -Password $vcpass

# Retrieve VM and only its Devices
$vm = Get-View -Server $server -ViewType VirtualMachine -Property Name,Config.Hardware.Device -Filter @{"Name" = $vmName}

# Array of Devices on VM
$vmDevices = $vm.Config.Hardware.Device

# Find the SCSI Controller we care about
foreach ($device in $vmDevices) {
    if($device -is [VMware.Vim.VirtualSCSIController] -and $device.BusNumber -eq $diskControllerNumber) {
        $diskControllerKey = $device.key
        break
    }
}

# Create VM Config Spec to add new VMDK & Enable Multi-Writer Flag
#for ($i=0 ; $i -le $diskNames.Count ; $i++) {
$VMData.disks | ForEach-Object {

    # Convert GB to KB
    $diskSizeInKB = (($_.size * 1024 * 1024 * 1024)/1KB)
    $diskSizeInKB = [Math]::Round($diskSizeInKB,4,[MidPointRounding]::AwayFromZero)

    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.deviceChange = New-Object VMware.Vim.VirtualDeviceConfigSpec

    $spec.deviceChange[0].operation = 'add'
    $spec.DeviceChange[0].FileOperation = 'create'
    $spec.deviceChange[0].device = New-Object VMware.Vim.VirtualDisk
    $spec.deviceChange[0].device.key = -1
    $spec.deviceChange[0].device.ControllerKey = $diskControllerKey
    
    $spec.deviceChange[0].device.CapacityInKB = $diskSizeInKB
    $spec.DeviceChange[0].device.backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
    $spec.DeviceChange[0].device.Backing.fileName = $_.name
    write-host "diskName" $_.name
    $spec.deviceChange[0].device.unitNumber = $_.diskNum
    $spec.DeviceChange[0].device.Backing.diskMode = "independent_persistent"
    $spec.DeviceChange[0].device.Backing.eagerlyScrub = $True
    $spec.DeviceChange[0].device.Backing.Sharing = "sharingMultiWriter"

# 3 second sleep seems necessary here
Start-Sleep 3
$task = $vm.ReconfigVM_Task($spec) 
$task1 = Get-Task -Id ("Task-$($task.value)") 
$task1 | Wait-Task 
}

#Make sure the first script finishes config before sharing disks
Start-Sleep 2

#Disconnect-VIServer $server -Confirm:$false

################################
######## SECOND SCRIPT #########
# This Script will add the Multi-Writer VMDKs created in the previous section
# to the next two nodes in the ORAC cluster

######## VARS #########
$MasterVM = $VMData.Name

# This is how the next two nodes are targeted
$Node2 = IncrementNodeNumber -node $MasterVM
$Node3 = IncrementNodeNumber -node $Node2

$SlaveVMs = @($Node2, $Node3)
write-host "Slave VMs: " $SlaveVMs

# Make sure the Master VM is powered off
$Result = Get-VM -Name $MasterVM
$PowerState = $Result.PowerState
if ($PowerState -ne "PoweredOff") {
    Get-VM -Name $MasterVM | Shutdown-VMGuest -Confirm:$false
    Start-Sleep 4
}

# Find the SCSI Controller we will add the disks to
foreach ($device in $vmDevices) {
    if($device -is [VMware.Vim.VirtualSCSIController] -and $device.BusNumber -eq $diskControllerNumber) {
        $diskControllerName = $device.DeviceInfo.Label
        #Write-Host $diskControllerName
        break
    }
}

# For each VM in Slave VM array; Loop through disks of Master and add them to the Slave VM
foreach ($Slave in $SlaveVMs) {
    $VM = Get-VM -Name $Slave
    $VMdata.disks | ForEach-Object {
        $diskName = $_.name
        Write-Host $diskName

        New-HardDisk -VM $VM -DiskPath $diskName -Controller $diskControllerName

    }

}

# Turn the Master Node back on
Start-VM -VM $MasterNode -RunAsync






CreateAndShareRACDisks