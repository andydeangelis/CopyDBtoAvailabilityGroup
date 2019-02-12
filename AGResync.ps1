<#
	.SYNOPSIS
		A brief description of the Invoke-AGResync_ps1 file.
	
	.DESCRIPTION
		A description of the file.
	
	.PARAMETER AGListener
		A description of the AGListener parameter.
	
	.PARAMETER SrcSqlInstance
		A description of the SrcSqlInstance parameter.
	
	.PARAMETER Database
		A description of the Database parameter.
	
	.PARAMETER destDataRootDir
		A description of the destDataRootDir parameter.
	
	.PARAMETER destLogRootDir
		A description of the destLogRootDir parameter.
	
	.PARAMETER BackupPath
		A description of the BackupPath parameter.
	
	.PARAMETER SrcDatabase
		A description of the SrcDatabase parameter.
	
	.NOTES
		===========================================================================
		Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2018 v5.5.150
		Created on:   	2/8/2019 1:48 PM
		Created by:   	andy-user
		Organization:
		Filename:     	AGResync.ps1
		===========================================================================
#>
param
(
	[Parameter(Mandatory = $true)]
	[string]$AGListener,
	[Parameter(Mandatory = $true)]
	[string]$SrcSqlInstance,
	[Parameter(Mandatory = $true)]
	[string]$Database,
	[Parameter(Mandatory = $true)]
	[string]$destDataRootDir,
	[Parameter(Mandatory = $true)]
	[string]$destLogRootDir,
	[Parameter(Mandatory = $true)]
	[string]$BackupPath
)

$datetime = get-date -f MM-dd-yyyy_hh.mm.ss

# Step 1 - Remove the existing database from the Availability Group.

Write-Host "Step 1 - Remove the existing database from the Availability Group." -ForegroundColor Green

$primary = Get-DbaAgReplica -SqlInstance $AGListener | ? { $_.Role -eq "Primary" }
$secondary = Get-DbaAgReplica -SqlInstance $AGListener | ? { $_.Role -eq "Secondary" }
$clNodes = Get-DbaWsfcNode -ComputerName $primary.ComputerName

Get-DbaAgDatabase -SqlInstance $AGListener -Database $Database | Remove-DbaAgDatabase -Confirm:$false 

# Step 2 - Remove the database from the primary node.

Write-Host "Step 2 - Remove the database from the primary node." -ForegroundColor Green

try
{
	Remove-DbaDatabase -SqlInstance $primary.Name -Database $Database -Confirm:$false 
}
catch
{
	"Unable to delete database."
}

# Step 3 - Remove the database from each secondary node.

Write-Host "Step 3 - Remove the database from each secondary node." -ForegroundColor Green

foreach ($replica in $secondary)
{	
	try
	{
		Remove-DbaDatabase -SqlInstance $replica.Name -Database $Database -Confirm:$false 
	}
	catch
	{
		"Unable to delete database."
	}
}

# Step 4 - Create the directory structure on each node.

Write-Host "Step 4 - Create the directory structure on each node." -ForegroundColor Green

foreach ($server in $clNodes)
{
	$server.Name
	try
	{
		Invoke-Command -ComputerName $server.Name -ScriptBlock {			
			if (-not (Test-Path "$($Using:destDataRootDir)\$($Using:Database)"))
			{
				Write-Host "$($Using:destDataRootDir)\$($Using:Database)" -ForegroundColor Yellow
				New-Item -ItemType Directory -Path "$($Using:destDataRootDir)\$($Using:Database)"
			}
		}
		
		Invoke-Command -ComputerName $server.Name -ScriptBlock {
			if (-not (Test-Path "$($Using:destLogRootDir)\$($Using:Database)"))
			{
				New-Item -ItemType Directory -Path "$($Using:destLogRootDir)\$($Using:Database)"
			}
		}
	}
	catch
	{
		"Unable to create directory structure on $($server.Name)."
	}	
}

# Step 5 - Copy the database from the source to the primary replica.

Write-Host "Step 5 - Copy the database from the source to the primary replica." -ForegroundColor Green

try
{
	$srcDBPathQuery = "SELECT DB_NAME(database_id) AS DatabaseName, name AS LogicalFileName, physical_name AS PhysicalFileName 
						FROM sys.master_files AS mf"
	$dbLogicalNames = Invoke-DbaQuery -SqlInstance $SrcSqlInstance -Query $srcDBPathQuery | ? {$_.DatabaseName -eq "$Database"}
	
	if (-not (Test-Path "$BackupPath\$datetime")) { New-Item -ItemType Directory -Path "$BackupPath\$datetime" -Force }
	
	Backup-DbaDatabase -SqlInstance $SrcSqlInstance -Database $Database -BackupDirectory "$BackupPath\$datetime" -BackupFileName "$($Database)_$datetime.bak"
		
	Restore-DbaDatabase -SqlInstance $primary.Name -DatabaseName $Database -Path "$BackupPath\$datetime\$($Database)_$datetime.bak" -DestinationDataDirectory "$destDataRootDir\$Database" -DestinationLogDirectory "$destLogRootDir\$Database"
	# Remove-Item -Path "$BackupPath\$datetime" -Recurse -Force
	# Copy-DbaDatabase -Source $SrcSqlInstance -Destination $primary.Name -Database $Database -BackupRestore -SharedPath $BackupPath
}
catch
{
	"Unable to copy database."
}

# Step 6 - Add the database to the Availability Group.

Write-Host "Step 6 - Add the database to the Availability Group." -ForegroundColor Green

$agName = Get-DbaAgListener -SqlInstance $AGListener | ?{ $_.Name -eq $AGListener }

try
{
	$primaryVer = Connect-DbaInstance -SqlInstance $primary.Name		
	
	if ($primaryVer.VersionMajor -lt 13)
	{
		$dbBackupQuery = "ALTER DATABASE $Database SET SINGLE_USER WITH ROLLBACK IMMEDIATE
							GO
							ALTER DATABASE $Database SET MULTI_USER
							GO

							backup database $Database to disk=N'$BackupPath\$datetime\$($Database)_AOAGSeed_$datetime.bak'
							backup log $Database to disk=N'$BackupPath\$datetime\$($Database)_AOAGSeed_$datetime.trn'
							alter availability group [$($agName.AvailabilityGroup)]
							add database [$Database];"
		
		$dbRestoreQuery = "Restore database $Database from disk='$BackupPath\$datetime\$($Database)_AOAGSeed_$datetime.bak' with norecovery
							restore log $Database from disk='$BackupPath\$datetime\$($Database)_AOAGSeed_$datetime.trn' with norecovery
							alter database $Database set HADR availability group= [$($agName.AvailabilityGroup)]"
		
		Invoke-DbaQuery -SqlInstance $primary.Name -Query $dbBackupQuery
		foreach ($instance in $secondary)
		{
			Invoke-DbaQuery -SqlInstance $instance.Name -Query $dbRestoreQuery
		}		
	}
	else
	{
		Add-DbaAgDatabase -SqlInstance $primary.Name -AvailabilityGroup $agName.AvailabilityGroup -Database $Database -SeedingMode Automatic -Confirm:$false
	}
}
catch
{
	"Unable to add database to the Availability Group."
}

# Step 7 - Clean up.

Write-Host "Step 7 - Clean up generated backup files..." -ForegroundColor Green
try
{
	Remove-Item -Path "$BackupPath\$datetime" -Recurse -Force
}
catch
{
	"Unable to clean up files."
}
