#!/bin/bash

#######################################################################
# Purpose: This script is used to reassign the Network Interface Card (NIC) 
#          from the Windows ZCA VM to the Linux ZCA within an Azure environment. 
#          Once the script is completed, the Linux ZCA is assigned with original Windows ZCA VM IP address.
#          The Windows ZCA VM is assigned with the provided alternative IP address.
#
# Prerequisites: This script assumes you have the required permissions and access rights 
#                to manage network resources within your Azure subscription.  
#                The source Windows ZCA and target Linux ZCA machines will be restarted.
#
# Steps:
#	     1. Launch the script on Azure Cloud Shell.  
#	     Authentication is automatic 
# 
#	     2. Run the following command: - az account set --subscription [subscription_ID]  
#	     The subscription ID must be the same for Windows ZCA and Linux ZCA. 
# 
#	     3. Run the following command: - chmod +x [script name]  
#	     This enables permissions to run the script. 
# 
#	     4. To execute the script run the following command: 
#      - ./reassign-nic.bash --original-zca-ip 127.10.10.10 --original-zvm-appliance-ip 127.10.10.11 --alternative-zca-ip 127.10.10.12 
# 
#	     5. To revert all changes run the following command:  
#      - ./reassign-nic.bash --original-zca-ip 127.10.10.10 --original-zvm-appliance-ip 127.10.10.11 --alternative-zca-ip 127.10.10.12 –revert 
#      Call the script exactly as in the reassignment execution run, adding '--revert' parameter without changing the original values. 
#      Once completed both VMs retain the original VM IP addresses. 
#######################################################################

# Set errexit option to stop processing when any command fails 
set -e

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
NORMAL=$(tput sgr0)

function logDebug () {
    if [[ $__VERBOSE -eq 1 ]]; then
        echo "$@"
    fi
}

function logInfo () {
    echo "$@"
}

function logError () {
    echo "${RED}$@${NORMAL}" >&2
}

getVmNameByIP() {
    local ipAddress="$1"

    local nic=$(az network nic list --query "[?ipConfigurations[0].privateIPAddress=='$ipAddress']")
    local vmName=$(echo "$nic" | jq -r 'try .[0].virtualMachine.id catch "" | split("/") | last')

    if [[ -z "$vmName" || "$vmName" = "null" ]]; then
        logError "VM with $ipAddress not found"
        exit 1
    else
        echo "$vmName"
    fi
}

getNicNameByIP() {
    local ipAddress="$1"

    local nicName=$(az network nic list --query "[?ipConfigurations[0].privateIPAddress=='$ipAddress']" | jq -r '.[0].name')

    if [ -z "$nicName" ]; then
        logError "${RED}NIC with $ipAddress not found${NORMAL}"
        exit 1
    else
        echo "$nicName"
    fi
}

getResourceGroupNameByIP() {
    local ipAddress="$1"

    local nic=$(az network nic list --query "[?ipConfigurations[0].privateIPAddress=='$ipAddress']")
    local resourceGroupName=$(echo "$nic" | jq -r '.[0].resourceGroup')

    if [ -z "$resourceGroupName" ]; then
        logError "Failed to find the Resource Group for NIC with address: $ipAddress"
        exit 1
    else
        echo "$resourceGroupName"
    fi
}

getLocationByIP() {
    local ipAddress="$1"

    local nic=$(az network nic list --query "[?ipConfigurations[0].privateIPAddress=='$ipAddress']")
    local regionName=$(echo "$nic" | jq -r '.[0].location')

    if [ -z "$regionName" ]; then
		logError "Failed to find Region for NIC with address: $ipAddress'"
		
        exit 1
    else
        echo "$regionName"
    fi
}

getNicSubnetByNicAndRG() {
	local nicName="$1"
	local nicResourceGroup="$2"

	local subnetId=$(az network nic show --name "$nicName" --resource-group $nicResourceGroup --query 'ipConfigurations[0].subnet.id')
	
	echo "$subnetId"
}

displayUsage() {
  echo "Usage: $0 --original-zca-ip <ipv4> --original-zvm-appliance-ip <ipv4> --alternative-zca-ip <ipv4> [--revert]"
}

validateIp() {
  local ip="$1"
  if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    logError "Invalid IP address format: $ip"
    exit 1
  fi
}

step_queue=()
function_queue=()
addRollbackStep(){
    step=$1
    func=$2

    step_queue+=("$step")
    function_queue+=("$func")
}

executeRollback(){
  logInfo "${YELLOW}Error occurred...${NORMAL}"

  for ((i=${#function_queue[@]}-1; i>=0; i--)); do
      rollbackIndex=$i
      item="${function_queue[i]}"
      step="${step_queue[i]}"
      stepIndex=$((i+1))

      IFS=' ' read -ra parts <<< "$item"
      function_name="${parts[0]}"
      parameters="${parts[@]:1}"

      logInfo "- undo step #$stepIndex: $step"
      $function_name ${parameters[@]} || return 1
  done

  logInfo "${YELLOW}Script steps were successfully rolled back${NORMAL}"
}

showRollbackLeftoverSteps(){
  logInfo "${YELLOW}Rollback steps that require manual execution:${NORMAL}"

  for ((i=$rollbackIndex-1; i>=0; i--)); do
      step="${step_queue[i]}"
      stepIndex=$((i+1))

      logInfo "- step #$stepIndex: $step"
  done
}

# Parse options
options=$(getopt -o "" -l original-zca-ip:,original-zvm-appliance-ip:,alternative-zca-ip:,verbose,revert -n "$0" -- "$@")
if [ $? -ne 0 ]; then
  displayUsage
  exit 1
fi
eval set -- "$options"

while true; do
  case "$1" in
    --original-zca-ip) zcaOriginalIp="$2"; shift 2 ;;
    --original-zvm-appliance-ip) zvmaOriginalIp="$2"; shift 2 ;;
    --alternative-zca-ip) alternativeZcaIp="$2"; shift 2 ;;
    --verbose) __VERBOSE=1; shift ;;
    --revert) __REVERT=1; shift ;;
    --) shift; break ;;
    *) displayUsage; exit 1 ;;
  esac
done

# Check if required parameters are missing
if [[ -z "$zcaOriginalIp" || -z "$zvmaOriginalIp" || -z "$alternativeZcaIp" ]]; then
  logError "Missing required parameter(s)."
  displayUsage
  exit 1
fi

# Validate IP formats
validateIp "$zcaOriginalIp"
validateIp "$zvmaOriginalIp"
validateIp "$alternativeZcaIp"

# Validate IP uniqueness
if [[ "$zcaOriginalIp" == "$zvmaOriginalIp" || "$zcaOriginalIp" == "$alternativeZcaIp" ||  "$zvmaOriginalIp" == "$alternativeZcaIp" ]]; then
  logError "Each VM IP address input must be unique"
  exit 1
fi

if [[ $__REVERT -eq 0 ]]; then
  # Init variables
  logInfo "Initialization..."
  zcaVmName=$(getVmNameByIP $zcaOriginalIp)
  logDebug "Windows ZCA VM name: ${GREEN}$zcaVmName${NORMAL}"

  zcaOriginalNicName=$(getNicNameByIP $zcaOriginalIp)
  logDebug "Windows ZCA NIC name: ${GREEN}$zcaOriginalNicName${NORMAL}"

  zvmaVmName=$(getVmNameByIP $zvmaOriginalIp)
  logDebug "Linux ZCA VM name: ${GREEN}$zvmaVmName${NORMAL}"

  zvmaOriginalNicName=$(getNicNameByIP $zvmaOriginalIp)
  logDebug "Linux ZCA NIC name: ${GREEN}$zvmaOriginalNicName${NORMAL}"

  zcaResourceGroupName=$(getResourceGroupNameByIP $zcaOriginalIp)
  logDebug "Windows ZCA Resource Group name: ${GREEN}$zcaResourceGroupName${NORMAL}"

  zvmaResourceGroupName=$(getResourceGroupNameByIP $zvmaOriginalIp)
  logDebug "Linux ZCA Resource Group name: ${GREEN}$zvmaResourceGroupName${NORMAL}"

  if [ "${zcaResourceGroupName^^}" != "${zvmaResourceGroupName^^}" ]; then
    logError "The Linux ZCA VM and the Windows ZCA VM are not part of the same resource group. To execute the migration process, both the Linux ZCA VM and the Windows ZCA VM must be assigned to the same resource group."
    exit 1
  fi

  sharedResourceGroupName=$zcaResourceGroupName
  
  alternativeZcaNicName="alternativeZcaNic$((RANDOM))"
  logDebug "Windows ZCA Alternative NIC name: ${GREEN}$alternativeZcaNicName${NORMAL}"

  zcaRegionName=$(getLocationByIP $zcaOriginalIp)
  logDebug "Windows ZCA Region name: ${GREEN}$zcaRegionName${NORMAL}"

  zvmaRegionName=$(getLocationByIP $zvmaOriginalIp)
  logDebug "Linux ZCA Region name: ${GREEN}$zvmaRegionName${NORMAL}"

  if [[ "$zcaRegionName" != "$zvmaRegionName" ]]; then
    logError "The Linux ZCA VM and the Windows ZCA VM are not located in the same region. To execute the migration process, both the Linux ZCA VM and the Windows ZCA VM must be located in the same region."
    exit 1
  fi

  zcaSubnetId=$(getNicSubnetByNicAndRG $zcaOriginalNicName $sharedResourceGroupName)
  logDebug "Windows ZCA Subnet id: ${GREEN}$zcaSubnetId${NORMAL}"

  zvmaSubnetId=$(getNicSubnetByNicAndRG $zvmaOriginalNicName $zvmaResourceGroupName)
  logDebug "Linux ZCA Subnet id: ${GREEN}$zvmaSubnetId${NORMAL}"

  if [ "$zcaSubnetId" != "$zvmaSubnetId" ]; then
    logError "The Linux ZCA VM and the Windows ZCA VM are not located in the same subnet. To execute the migration process, both the Linux ZCA VM and the Windows ZCA VM must be located in the same subnet."
    exit 1
  fi

  # Create the alternative NIC
  {
    logInfo "Creating: $alternativeZcaNicName as an alternative NIC for Windows ZCA"
    zcaNicJson=$(az network nic list --query "[?ipConfigurations[0].privateIPAddress=='$zcaOriginalIp']")
    logDebug "Windows ZCA NIC: $zcaNicJson"
    zcaLocation=$(echo "$zcaNicJson" | jq -r '.[0].location')
    logDebug $"Windows ZCA Location: $zcaLocation"
    if [ -z "$zcaLocation" ]; then
          logError "Failed to find location for NIC with address: $zcaOriginalIp"
          exit 1
    fi
    zcaSubnetId=$(echo "$zcaNicJson" | jq -r '.[0].ipConfigurations[0].subnet.id')
    logDebug $"Windows ZCA Subnet: $zcaSubnetId"
    if [ -z "$zcaSubnetId" ]; then
          logError "Failed to find Subnet for NIC with address: $zcaOriginalIp"
          exit 1
    fi

    az network nic create \
    --resource-group $sharedResourceGroupName \
    --name $alternativeZcaNicName \
    --location $zcaLocation \
    --subnet $zcaSubnetId \
    --private-ip-address $alternativeZcaIp \
    --output none &&

    addRollbackStep "Delete alternative Windows ZCA NIC" "az network nic delete --name $alternativeZcaNicName --resource-group $sharedResourceGroupName"
  } &&

  # Stop VMs
  {
    logInfo "Stopping Linux ZCA VM: $zvmaVmName"
    az vm deallocate --resource-group $sharedResourceGroupName --name $zvmaVmName &&

    addRollbackStep "Starting Linux ZCA" "az vm start --resource-group $sharedResourceGroupName --name $zvmaVmName --no-wait"
  } &&

  {
    logInfo "Stopping Windows ZCA VM: $zcaVmName"
    az vm deallocate --resource-group $sharedResourceGroupName --name $zcaVmName &&

    addRollbackStep "Starting Windows ZCA VM" "az vm start --resource-group $sharedResourceGroupName --name $zcaVmName --no-wait"
  } &&

  # Change NICs
  {
    logInfo "Changing network configuration for Windows ZCA VM"
    az vm nic add --nics $alternativeZcaNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none &&
    addRollbackStep "Detaching alternative NIC from Windows ZCA VM" "az vm nic remove --nics $alternativeZcaNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none"
  } &&
  { 
    az vm nic remove --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none &&
    addRollbackStep "Attaching original NIC to Windows ZCA VM" "az vm nic add --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none"
  } &&

  {
    logInfo "Changing network configuration for Linux ZCA VM"
    az vm nic add --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none &&
    addRollbackStep "Detaching original Windows ZCA NIC from Linux ZCA VM" "az vm nic remove --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none"
  } &&
  {
    az vm nic remove --nics $zvmaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none &&
    addRollbackStep "Attaching original NIC to Linux ZCA VM" "az vm nic add --nics $zvmaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none"
  } &&

  # Start VMs
  {
    logInfo "Starting Windows ZCA VM: $zcaVmName"
    az vm start --resource-group $sharedResourceGroupName --name $zcaVmName --no-wait &&
    addRollbackStep "Stopping Windows ZCA VM" "az vm deallocate --resource-group $sharedResourceGroupName --name $zcaVmName"
  } &&

  {
    logInfo "Starting Linux ZCA VM: $zvmaVmName"
    az vm start --resource-group $sharedResourceGroupName --name $zvmaVmName --no-wait &&
    addRollbackStep "Stopping Linux ZCA VM" "az vm deallocate --resource-group $sharedResourceGroupName --name $zvmaVmName"
  } &&

  # Print results
  {
    logInfo "${GREEN}Windows ZCA NIC was assigned to Linux ZCA VM${NORMAL}"
    logInfo "To connect to Windows ZCA use ${GREEN}$alternativeZcaIp${NORMAL}"
    logInfo "To connect to Linux ZCA use ${GREEN}$zcaOriginalIp${NORMAL}"
    logInfo "To undo changes you can use the following command:"
    logInfo " -> $0 --original-zca-ip $zcaOriginalIp --original-zvm-appliance-ip $zvmaOriginalIp --alternative-zca-ip $alternativeZcaIp --revert"
  } ||
  {
    executeRollback &&
    logInfo "${RED}Windows ZCA NIC wasn't assigned to Linux ZCA VM${NORMAL}" &&
    logInfo "${RED}Monitor script messages to track failed steps. In case of failure, re-run the revert operation or contact support${NORMAL}" &&
    exit 1
  } ||
  {
    logInfo "${RED}Windows ZCA NIC wasn't assigned to Linux ZCA VM${NORMAL}"
    logInfo "${RED}Rollback was not executed properly. Re-run the revert command or contact support${NORMAL}"
    showRollbackLeftoverSteps
    exit 1
  }
else
  # Init variables
  logInfo "Revert initialization..."
  zcaVmName=$(getVmNameByIP $alternativeZcaIp)
  logDebug "Windows ZCA VM name: ${GREEN}$zcaVmName${NORMAL}"

  zcaOriginalNicName=$(getNicNameByIP $zcaOriginalIp)
  logDebug "Windows ZCA Original NIC name: ${GREEN}$zcaOriginalNicName${NORMAL}"

  zvmaVmName=$(getVmNameByIP $zcaOriginalIp)
  logDebug "Linux ZCA VM name: ${GREEN}$zvmaVmName${NORMAL}"

  zvmaOriginalNicName=$(getNicNameByIP $zvmaOriginalIp)
  logDebug "Linux ZCA Original NIC name: ${GREEN}$zvmaOriginalNicName${NORMAL}"

  sharedResourceGroupName=$(getResourceGroupNameByIP $zcaOriginalIp)
  logDebug "Resource Group name: ${GREEN}$sharedResourceGroupName${NORMAL}"

  alternativeZcaNicName=$(getNicNameByIP $alternativeZcaIp)
  logDebug "Windows ZCA Alternative NIC name: ${GREEN}$alternativeZcaNicName${NORMAL}"

  # Stop VMs
  {
    logInfo "Stopping Linux ZCA VM: $zvmaVmName"
    az vm deallocate --resource-group $sharedResourceGroupName --name $zvmaVmName &&
    addRollbackStep "Starting Linux ZCA" "az vm start --resource-group $sharedResourceGroupName --name $zvmaVmName --no-wait"
  } &&

  {
    logInfo "Stopping Windows ZCA VM: $zcaVmName"
    az vm deallocate --resource-group $sharedResourceGroupName --name $zcaVmName &&
    addRollbackStep "Starting Windows ZCA VM" "az vm start --resource-group $sharedResourceGroupName --name $zcaVmName --no-wait"
  } &&

  # Change NICs
  {
    logInfo "Changing network configuration for Linux ZCA VM"
    az vm nic add --nics $zvmaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none &&
    addRollbackStep "Detaching original NIC from Linux ZCA VM" "az vm nic remove --nics $zvmaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none"
  } &&
  { 
    az vm nic remove --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none &&
    addRollbackStep "Attaching original Windows ZCA NIC to Linux ZCA VM" "az vm nic add --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zvmaVmName --output none"
  } &&
  
  {
    logInfo "Changing network configuration for Windows ZCA VM"
    az vm nic add --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none &&
    addRollbackStep "Detaching original NIC from Windows ZCA VM" "az vm nic remove --nics $zcaOriginalNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none"
  } &&
  {
    az vm nic remove --nics $alternativeZcaNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none &&
    addRollbackStep "Attaching alternative NIC to Windows ZCA VM" "az vm nic add --nics $alternativeZcaNicName --resource-group $sharedResourceGroupName --vm-name $zcaVmName --output none"
  } &&

  # Start VMs
  {
    logInfo "Starting Windows ZCA VM: $zcaVmName"
    az vm start --resource-group $sharedResourceGroupName --name $zcaVmName --no-wait &&
    addRollbackStep "Stopping Windows ZCA VM" "az vm deallocate --resource-group $sharedResourceGroupName --name $zcaVmName"
  } &&

  {
    logInfo "Starting Linux ZCA VM: $zvmaVmName"
    az vm start --resource-group $sharedResourceGroupName --name $zvmaVmName --no-wait &&
    addRollbackStep "Stopping Linux ZCA VM" "az vm deallocate --resource-group $sharedResourceGroupName --name $zvmaVmName"
  } &&

  # Delete the alternative NIC
  {
    logInfo "Deleting alternative Windows ZCA NIC"
    az network nic delete --name $alternativeZcaNicName --resource-group $sharedResourceGroupName ||
    logInfo "${YELLOW}The $alternativeZcaNicName wasn't deleted. You may need to delete it manually${NORMAL}"
  } && 

  # Print results
  {
    logInfo "${GREEN}The changes to the NICs were reverted${NORMAL}"
    logInfo "To connect to Windows ZCA use ${GREEN}$zcaOriginalIp${NORMAL}"
    logInfo "To connect to Linux ZCA use ${GREEN}$zvmaOriginalIp${NORMAL}"
  } ||
  {
    executeRollback &&
    logInfo "${RED}The changes to the NICs were not reverted${NORMAL}" &&
    logInfo "${RED}Monitor script messages to track failed steps. In case of failure, re-run the revert operation or contact support${NORMAL}" &&
    exit 1
  } ||
  {
    logInfo "${RED}The changes to the NICs were not reverted${NORMAL}"
    logInfo "${RED}Rollback was not executed properly. Re-run the revert command or contact support${NORMAL}"
    showRollbackLeftoverSteps
    exit 1
  }
fi
