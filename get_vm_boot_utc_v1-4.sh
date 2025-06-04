#!/bin/bash

region=""
resource_group=""
subscription=""
output_txt="vm_boot_report.txt"
output_csv="vm_boot_report.csv"
start_time=""
end_time=""

trap 'echo -e "\n❌ Script interrupted. Exiting..."; exit 1' INT

# --------------------------
# Parse CLI arguments
# --------------------------
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --region) region="$2"; shift ;;
        --resource-group) resource_group="$2"; shift ;;
        --subscription) subscription="$2"; shift ;;
        --start) start_time="$2"; shift ;;
        --end) end_time="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

sub_opt=""
[[ -n "$subscription" ]] && sub_opt="--subscription $subscription"

# Output file headers
echo "VM Name | Resource Group | OS Type | Power State | Boot Time (UTC) | Status" > "$output_txt"
echo "\"VM Name\",\"Resource Group\",\"OS Type\",\"Power State\",\"Boot Time (UTC)\",\"Within Outage Timeframe?\"" > "$output_csv"

# Get VMs
vm_list=$(az vm list $sub_opt --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, location:location}" -o tsv)
[[ -z "$vm_list" ]] && echo "❌ No VMs found in the subscription." && exit 0

matched_vms=0

while read vm_name rg_name os_type vm_location; do
    [[ -n "$region" && "$vm_location" != "$region" ]] && continue
    [[ -n "$resource_group" && "$rg_name" != "$resource_group" ]] && continue

    matched_vms=$((matched_vms + 1))

    echo "----------------------------"
    echo "Checking VM: $vm_name | RG: $rg_name | OS: $os_type | Region: $vm_location"

    power_state=$(az vm get-instance-view --name "$vm_name" --resource-group "$rg_name" $sub_opt \
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" -o tsv 2>/dev/null)
    power_state="${power_state#PowerState/}"

    if [[ "$power_state" != "running" ]]; then
        echo "⚠️  $vm_name is not running"
        status="VM is not in running state"
        echo "$vm_name | $rg_name | $os_type | $power_state | $status | N/A" >> "$output_txt"
        echo "\"$vm_name\",\"$rg_name\",\"$os_type\",\"$power_state\",\"$status\",\"N/A\"" >> "$output_csv"
        continue
    fi

    # Boot time retrieval
    if [[ "$os_type" == "Windows" ]]; then
        boot_time=$(timeout 120s az vm run-command invoke \
            --name "$vm_name" --resource-group "$rg_name" $sub_opt \
            --command-id RunPowerShellScript \
            --scripts "[System.TimeZoneInfo]::ConvertTimeToUtc((Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime)" \
            --query "value[0].message" -o tsv 2>/dev/null | tr -d '\r')
        [[ $? -ne 0 || -z "$boot_time" ]] && boot_time="VM command timed out or failed"
    elif [[ "$os_type" == "Linux" ]]; then
        boot_time=$(timeout 120s az vm run-command invoke \
            --name "$vm_name" --resource-group "$rg_name" $sub_opt \
            --command-id RunShellScript \
            --scripts "uptime -s" \
            --query "value[0].message" -o tsv 2>/dev/null | \
            awk '/^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {print $0}' | \
            xargs -I {} date -u -d "{}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)
        [[ $? -ne 0 || -z "$boot_time" ]] && boot_time="VM command timed out or failed"
    else
        boot_time="Unknown OS type"
    fi

    # Logic for display
    if [[ "$boot_time" == "VM command timed out or failed" ]]; then
        status="⚠️  Failed to retrieve boot time"
        echo "⚠️  $vm_name is running but failed to retrieve boot time"
    else
        echo "✅  $vm_name booted at (UTC): $boot_time"
        if [[ -n "$start_time" && -n "$end_time" ]]; then
            boot_ts=$(date -u -d "$boot_time" +%s 2>/dev/null)
            start_ts=$(date -u -d "$start_time" +%s 2>/dev/null)
            end_ts=$(date -u -d "$end_time" +%s 2>/dev/null)

            if [[ $boot_ts -ge $start_ts && $boot_ts -le $end_ts ]]; then
                status="🔴 Within the timeframe of the outage!"
                echo "$status"
            else
                status="🟢 Outside of the timeframe of the outage."
                echo "$status"
            fi
        else
            status="N/A"
        fi
    fi

    # Write to files
    echo "$vm_name | $rg_name | $os_type | $power_state | $boot_time | $status" >> "$output_txt"
    # Determine CSV-safe status flag
if [[ "$boot_time" == "VM command timed out or failed" || "$power_state" != "running" ]]; then
    csv_outage_flag="N/A"
    csv_boot_time="N/A"
elif [[ -n "$start_time" && -n "$end_time" ]]; then
    boot_ts=$(date -u -d "$boot_time" +%s 2>/dev/null)
    start_ts=$(date -u -d "$start_time" +%s 2>/dev/null)
    end_ts=$(date -u -d "$end_time" +%s 2>/dev/null)

    if [[ $boot_ts -ge $start_ts && $boot_ts -le $end_ts ]]; then
        csv_outage_flag="Yes"
    else
        csv_outage_flag="No"
    fi
    csv_boot_time="$boot_time"
else
    csv_outage_flag="N/A"
    csv_boot_time="$boot_time"
fi

echo "\"$vm_name\",\"$rg_name\",\"$os_type\",\"$power_state\",\"$csv_boot_time\",\"$csv_outage_flag\"" >> "$output_csv"

done <<< "$vm_list"

# Summary
if [[ "$matched_vms" -eq 0 ]]; then
    echo -e "\n❌ No VMs matched the provided region/resource group filters."
    rm -f "$output_txt" "$output_csv" 2>/dev/null
else
    echo -e "\n✅ Done. Reports saved to:"
    echo "   • $output_txt"
    echo "   • $output_csv"
fi
