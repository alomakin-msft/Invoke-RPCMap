<#
.SYNOPSIS

Invoke-RPCMap can be used to enumerate local and remote RPC services/ports via the RPC Endpoint Mapper
service.

.DESCRIPTION

Invoke-RPCMap can be used to enumerate local and remote RPC services/ports via the RPC Endpoint Mapper
service.

This information can useful during an investigation where a connection to a remote port is known, but
the service is running under a generic process like svchost.exe.

This script will do the following:
- Create a local log file
- Connect to the RPC Endpoint Mapper service and retreive a list of ports/uuids
- Compare the returned uuids to the list in the script to indentify the service name
- Print the results
- Map the next host if multiple hosts are provided
- Open the log file (optional)

Author - Rob Willis @b1t_r0t
Blog: robwillis.info

The core of this script was sourced from the following script:
https://devblogs.microsoft.com/scripting/testing-rpc-ports-with-powershell-and-yes-its-as-much-fun-as-it-sounds/

.EXAMPLE

Basic usage (will scan local host):
C:\PS> PowerShell.exe -ExecutionPolicy Bypass .\Invoke-RPCMap.ps1

Add -targetHosts or -t (alias) to scan multiple hosts:
C:\PS> PowerShell.exe -ExecutionPolicy Bypass .\Invoke-RPCMap.ps1 -t localhost,host1,192.168.1.50
C:\PS> PowerShell.exe -ExecutionPolicy Bypass .\Invoke-RPCMap.ps1 -targetHosts localhost,host1,192.168.1.50

Add -openLog or -o (alias) to open the log file in notepad when the script has completed:
C:\PS> PowerShell.exe -ExecutionPolicy Bypass .\Invoke-RPCMap.ps1 -t localhost,host1,192.168.1.50 -o
C:\PS> PowerShell.exe -ExecutionPolicy Bypass .\Invoke-RPCMap.ps1 -t localhost,host1,192.168.1.50 -openLog

#>
[CmdletBinding()] Param(
[Parameter(Mandatory = $false)]
[Alias("t")]
[string[]]$targetHosts = 'localhost',

[Parameter(Mandatory = $false)]
[Alias("o")]
[switch]$openLog
)

# Clear the screen - RW
clear

# Set up logging - RW
# Create a timestamp to use for a unique enough filename
$timeStamp = Get-Date -format "MMM-dd-yyyy_HH-mm"
# Create the output path
$outputPath = $pwd.path + "\" + "Invoke-RPCMap_" + $timeStamp + ".txt"
$startLog = Start-Transcript $outputPath

# Author: Ryan Ries [MSFT]
# Origianl date: 15 Feb. 2014
#Requires -Version 3
Function Invoke-RPCMap
{
    [CmdletBinding(SupportsShouldProcess=$True)]
    Param([Parameter(ValueFromPipeline=$True)][String[]]$ComputerName = 'localhost')
    BEGIN
    {
        Set-StrictMode -Version Latest
        # Force Computer to be ComputerName - RW
        $Computer = $ComputerName
        $PInvokeCode = @'
        using System;
        using System.Collections.Generic;
        using System.Runtime.InteropServices;



        public class Rpc
        {
            // I found this crud in RpcDce.h

            [DllImport("Rpcrt4.dll", CharSet = CharSet.Auto)]
            public static extern int RpcBindingFromStringBinding(string StringBinding, out IntPtr Binding);

            [DllImport("Rpcrt4.dll")]
            public static extern int RpcBindingFree(ref IntPtr Binding);

            [DllImport("Rpcrt4.dll", CharSet = CharSet.Auto)]
            public static extern int RpcMgmtEpEltInqBegin(IntPtr EpBinding,
                                                    int InquiryType, // 0x00000000 = RPC_C_EP_ALL_ELTS
                                                    int IfId,
                                                    int VersOption,
                                                    string ObjectUuid,
                                                    out IntPtr InquiryContext);

            [DllImport("Rpcrt4.dll", CharSet = CharSet.Auto)]
            public static extern int RpcMgmtEpEltInqNext(IntPtr InquiryContext,
                                                    out RPC_IF_ID IfId,
                                                    out IntPtr Binding,
                                                    out Guid ObjectUuid,
                                                    out IntPtr Annotation);

            [DllImport("Rpcrt4.dll", CharSet = CharSet.Auto)]
            public static extern int RpcBindingToStringBinding(IntPtr Binding, out IntPtr StringBinding);

            public struct RPC_IF_ID
            {
                public Guid Uuid;
                public ushort VersMajor;
                public ushort VersMinor;
            }


            // Returns a dictionary of <Uuid, port>
            public static Dictionary<string, List<int>> QueryEPM(string host)
            {
                Dictionary<string, List<int>> ports_and_uuids = new Dictionary<string, List<int>>();
                int retCode = 0; // RPC_S_OK

                IntPtr bindingHandle = IntPtr.Zero;
                IntPtr inquiryContext = IntPtr.Zero;
                IntPtr elementBindingHandle = IntPtr.Zero;
                RPC_IF_ID elementIfId;
                Guid elementUuid;
                IntPtr elementAnnotation;

                try
                {
                    retCode = RpcBindingFromStringBinding("ncacn_ip_tcp:" + host, out bindingHandle);
                    if (retCode != 0)
                        throw new Exception("RpcBindingFromStringBinding: " + retCode);

                    retCode = RpcMgmtEpEltInqBegin(bindingHandle, 0, 0, 0, string.Empty, out inquiryContext);
                    if (retCode != 0)
                        throw new Exception("RpcMgmtEpEltInqBegin: " + retCode);

                    do
                    {
                        IntPtr bindString = IntPtr.Zero;
                        retCode = RpcMgmtEpEltInqNext(inquiryContext, out elementIfId, out elementBindingHandle, out elementUuid, out elementAnnotation);
                        if (retCode != 0)
                            if (retCode == 1772)
                                break;

                        retCode = RpcBindingToStringBinding(elementBindingHandle, out bindString);
                        if (retCode != 0)
                            throw new Exception("RpcBindingToStringBinding: " + retCode);

                        string s = Marshal.PtrToStringAuto(bindString).Trim().ToLower();
                        if (s.StartsWith("ncacn_ip_tcp:"))
                            if (ports_and_uuids.ContainsKey(elementIfId.Uuid.ToString()))
                            {
                                ports_and_uuids[elementIfId.Uuid.ToString()].Add(int.Parse(s.Split('[')[1].Split(']')[0]));
                            }
                            else
                            {
                                ports_and_uuids.Add(elementIfId.Uuid.ToString(), new List<int>() { int.Parse(s.Split('[')[1].Split(']')[0]) });
                            }

                        RpcBindingFree(ref elementBindingHandle);

                    }
                    while (retCode != 1772); // RPC_X_NO_MORE_ENTRIES

                }
                catch (Exception ex)
                {
                    Console.WriteLine(ex);
                    return ports_and_uuids;
                }
                finally
                {
                    RpcBindingFree(ref bindingHandle);
                }

                return ports_and_uuids;
            }
        }
'@
    }
    PROCESS
    {

        [Bool]$EPMOpen = $False
        [Bool]$bolResult = $False
        $Socket = New-Object Net.Sockets.TcpClient

        Try
        {
            $Socket.Connect($ComputerName, 135)
            If ($Socket.Connected)
            {
                $EPMOpen = $True
            }
            $Socket.Close()
        }
        Catch
        {
            $Socket.Dispose()
            ""
            "+-------------------------------------------------------------------------------------------------------------+"
            ""
            Write-Host "Unable to connect to:"
            Write-Host "$ComputerName" -ForegroundColor Red
            ""
        }

        If ($EPMOpen)
        {
            Add-Type $PInvokeCode

            # Build the UUID Mapping hash table - RW
            $uuidMapping = @{
                "51a227ae-825b-41f2-b4a9-1ac9557a1018" = "Ngc Pop Key Service"
                "367abb81-9844-35f1-ad32-98f038001003" = "Service Control Manager/Services"
                "12345678-1234-abcd-ef00-0123456789ab" = "Printer Spooler Service"
                "f6beaff7-1e19-4fbb-9f8f-b89e2018337c" = "Event Log TCPIP"
                "86d35949-83c9-4044-b424-db363231fd0c" = "Task Scheduler Service"
                "d95afe70-a6d5-4259-822e-2c84da1ddb0d" = "WindowsShutdown Interface"
                "3c4728c5-f0ab-448b-bda1-6ce01eb0a6d5" = "DHCP Client LRPC Endpoint"
                "3c4728c5-f0ab-448b-bda1-6ce01eb0a6d6" = "DHCPv6 Client LRPC Endpoint"
                "0b1c2170-5732-4e0e-8cd3-d9b16f3b84d7" = "RemoteAccessCheck"
                "12345678-1234-abcd-ef00-01234567cffb" = "Net Logon Service"
                "12345778-1234-abcd-ef00-0123456789ab" = "LSA Access"
                "12345778-1234-abcd-ef00-0123456789ac" = "SAM Access"
                "8fb74744-b2ff-4c00-be0d-9ef9a191fe1b" = "Ngc Pop Key Service"
                "b25a52bf-e5dd-4f4a-aea6-8ca7272a0e86" = "KeyIso"
                "c9ac6db5-82b7-4e55-ae8a-e464ed7b4277" = "Impl Friendly Name"
                "e3514235-4b06-11d1-ab04-00c04fc2dcd2" = "MS NT Directory DRS Interface"
                "0d3c7f20-1c8d-4654-a1b3-51563b298bda" = "UserMgrCli"
                "1ff70682-0a51-30e8-076d-740be8cee98b" = "Scheduler Service"
                "201ef99a-7fa0-444c-9399-19ba84f12a1a" = "AppInfo"
                "2e6035b2-e8f1-41a7-a044-656b439c4c34" = "Proxy Manager Provider Server Endpoint"
                "552d076a-cb29-4e44-8b6a-d15e59e2c0af" = "IP Transition Configuration Endpoint"
                "58e604e8-9adb-4d2e-a464-3b0683fb1480" = "AppInfo"
                "5f54ce7d-5b79-4175-8584-cb65313a0e98" = "AppInfo"
                "b18fbab6-56f8-4702-84e0-41053293a869" = "UserMgrCli"
                "c36be077-e14b-4fe9-8abc-e856ef4f048b" = "Proxy Manager Client Server Endpoint"
                "c49a5a70-8a7f-4e70-ba16-1e8f1f193ef1" = "Adh APIs"
                "fb9a3757-cff0-4db0-b9fc-bd6c131612fd" = "AppInfo"
                "fd7a0523-dc70-43dd-9b2e-9c5ed48225b1" = "AppInfo"
                "6b5bdd1e-528c-422c-af8c-a4079be4fe48" = "Windows Firewall Remote Service"
                "897e2e5f-93f3-4376-9c9c-fd2277495c27" = "DFS-R replication Interface"
                "76f03f96-cdfd-44fc-a22c-64950a001209" = "IRemoteWinspool Server"
                "50abc2a4-574d-40b3-9d66-ee4fd5fba076" = "DNS Server"
                "3a9ef155-691d-4449-8d05-09ad57031823" = "Task Scheduler Service"
                "ae33069b-a2a8-46ee-a235-ddfd339be281" = "Print System Asynchronous Notification"
            }

            # Dictionary <Uuid, Port>
            $RPC_ports_and_uuids = [Rpc]::QueryEPM($Computer)
            # Write the hostname, ports, and uuids - RW
            ""
            "+-------------------------------------------------------------------------------------------------------------+"
            ""
            Write-Host "Scanning:"
            Write-Host "$ComputerName" -ForegroundColor Green
            ""
            # Initialize the new hash table to store the results of the scan results vs uuid mapping - RW
            $enrichedResults = @{}
            # Search the results for matches in the RPC port and uuid hash table
            foreach ($uuid in $RPC_ports_and_uuids.Keys) {
                # Grab just the uuid from the hash table via port key
                # Now query the uuidMapping for a match
                if ($uuidMapping.ContainsKey($uuid)) {
                    # There was a match, now create a new hash table with the updated informaton
                    # Associate the uuid with the name
                    $mappingResultName = $uuidMapping.Item($uuid)
                    # Add the results to the new enriched results hash table
                    $enrichedResults.Add($uuid + " (" + "$mappingResultName" + ")",($RPC_ports_and_uuids[$uuid] -join ", "))
                } else {
                    # There was not a match to the uuid mapping
                    # Add the port and uuid from the original RPC port and uuid hash table
                    $enrichedResults.Add($uuid,($RPC_ports_and_uuids[$uuid] -join ", "))
                }
            }
            Write-Output "Results:"
            # Format the results
            $enrichedResults.Keys | Select @{l='UUID (Service Name)';e={$_}},@{l='Port(s)';e={$enrichedResults.$_}} | out-host

        }


    }

    END
    {

    }
}

# Execute - RW

""
"+-------------------------------------------------------------------------------------------------------------+"
"| Invoke-RPCMap v0.1"
"+-------------------------------------------------------------------------------------------------------------+"
""
Write-Output "Saving log file to: $outputPath"

ForEach ($targetHost in $targetHosts) {
    Invoke-RPCMap -ComputerName $targetHost
}

"+-------------------------------------------------------------------------------------------------------------+"
""
$stopLog = Stop-Transcript

# If the open log switch is present, open the log file with notepad
if ($openLog.IsPresent) {
    notepad $outputPath
}
