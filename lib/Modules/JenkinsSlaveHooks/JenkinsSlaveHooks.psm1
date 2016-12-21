Import-Module JujuHelper
Import-Module JujuHooks
Import-Module JujuUtils
Import-Module JujuWindowsUtils
Import-Module Templating
Import-Module powershell-yaml

$charmDir = Get-JujuCharmDir
$TEMPLATE_DIR =  Join-Path $charmDir "templates"
$INSTALL_DIR = Join-Path $env:ProgramFiles "Jenkins-Slave"
$JAVA_DIR = Join-Path $env:ProgramFiles "Java\jre"

function CheckDir($path)
{
    if (!(Test-Path -path $path))
    {
        mkdir $path
    }
}

function CheckRemoveDir($path)
{
    if (Test-Path $path) {
        Remove-Item -Recurse -Force $path
    }
}

function Get-JavaInstaller {
    $url = Get-JujuCharmConfig -Scope 'java-url'
    $uri = [Uri]$url
    $outFile = $uri.PathAndQuery.Substring($uri.PathAndQuery.LastIndexOf("/") + 1)
    $installerPath = Join-Path $env:TEMP $outFile
    $client = new-object System.Net.WebClient 
    $cookie = "oraclelicense=accept-securebackup-cookie"
    $client.Headers.Add([System.Net.HttpRequestHeader]::Cookie, $cookie)
    Write-JujuLog "Downloading Java installer"
    $client.downloadFile($url, $installerPath)
    return $installerPath
}

function Get-SlaveAgent {
    $ctx = Get-RelationContext
    if (!$ctx.Count){
        # Context is empty. Probably peer not ready
        Write-JujuWarning ("Context for jenkins-slave is not ready")
        exit 0
    }
	$jenkins_url = $ctx['url']
    $slavejar_url = $jenkins_url + '/jnlpJars/slave.jar'
    CheckDir $INSTALL_DIR
    $outFile = 'slave.jar'
    $SlaveAgentPath = Join-Path $INSTALL_DIR $outFile

    Write-JujuLog "Downloading jenkins-slave installer"
    $startTime = Get-Date
    Invoke-FastWebRequest -Uri $slavejar_url -OutFile $SlaveAgentPath | Out-Null
    $endTime = Get-Date

    $downloadingDuration = $endTime.Subtract($startTime).Seconds
    Write-JujuLog "Downloading duration: $downloadingDuration second(s)"
    return $SlaveAgentPath
}

function Get-RelationContext {
    $required = @{
        "url"=$null;
        "username"=$null;
        "password"=$null;
    }
	$ctx = Get-JujuRelationContext -Relation 'slave' -RequiredContext $required
    if (!$ctx.Count){
            # Context is empty. Probably peer not ready
#            Write-JujuWarning ("Context for url is EMPTY")
            exit 0
            }
    return $ctx
}

function Get-JnlpContext {
    $slavehost = $env:computername
    $ctx = Get-RelationContext
    $jenkins_url = $ctx['url']
    $jenkins_username = $ctx['username']
    $jenkins_password = $ctx['password']
    $jnlpUrl = $jenkins_url + '/computer/' + $slavehost + '/slave-agent.jnlp'
    $jnlpCredentials = "`"$jenkins_username`":`"$jenkins_password`""
    $context = @{
    'jenkins_url' = $jenkins_url
    'jenkins_username' = $jenkins_username
    'jenkins_password' = $jenkins_password
    'jnlpUrl' = $jnlpUrl
    'jnlpCredentials' = $jnlpCredentials
    'slavehost' = $slavehost
    }
    return $context
}

function Get-CharmServices {
    return @{
        "jenkins-slave" = @{
            "template" = "jenkins-slave.xml";
            "service" = "jenkins slave";
            "config" = (Join-Path $env:ProgramFiles "Jenkins-Slave\jenkins-slave.xml");
            "service_bin_path" = "`"$INSTALL_DIR\jenkins-slave.exe`""
        };
    }
}

function Start-CopyTemplates {
	Copy-Item $TEMPLATE_DIR\jenkins-slave.exe $INSTALL_DIR\jenkins-slave.exe
	Copy-Item $TEMPLATE_DIR\jenkins-slave.exe.config $INSTALL_DIR\jenkins-slave.exe.config
}

function Start-ConfigTemplate {
    $ctx = Get-JnlpContext
    $java_exe = $JAVA_DIR + "/bin/java.exe"
    $jenkins_url = $ctx['jenkins_url']
    $jnlpUrl = $ctx['jnlpUrl']
    $jnlpCredentials = $ctx['jnlpCredentials']
    $slave_xml = Get-Content $TEMPLATE_DIR\jenkins-slave.xml

    $slave_xml = $slave_xml -replace "{{ java_exe }}","$java_exe"
    $slave_xml = $slave_xml -replace "{{ jnlpUrl }}","$jnlpUrl"
    $slave_xml = $slave_xml -replace "{{ jnlpCredentials }}","$jnlpCredentials"

    $slave_xml | Out-File $INSTALL_DIR\jenkins-slave.xml
}

function Start-SetJenkinsService {
    $services = Get-CharmServices
    $slaveservice = Get-Service $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
    if(!$slaveservice) {
        New-Service -Name $services["jenkins-slave"]["service"] `
                    -BinaryPathName $services["jenkins-slave"]["service_bin_path"] `
                    -DisplayName "jenkins slave" -Description "This service runs a slave for Jenkins continuous integration system." -Confirm:$false
    }
    Get-Service -Name $services["jenkins-slave"]["service"] | Set-Service -StartupType Automatic
}

function Start-InstallHook {
    $installerPath = Get-JavaInstaller
    $unattendedParams = @("INSTALLDIR=`"$JAVA_DIR`"", "/L", "$env:APPDATA\java_log.txt", "/s")
    Write-JujuLog "Installing Java"
    Start-Process -FilePath $installerPath -ArgumentList $unattendedParams -Wait -PassThru

    try {
        & "$JAVA_DIR\bin\java.exe" -version
    }
    catch {
        Write-JujuLog "Java installation failed"
    }

    Remove-Item $installerPath
}

function Start-ConfigChangedHook {
    $slave_redownload = Get-JujuCharmConfig -Scope 'slave-redownload'
    $executors = Get-JujuCharmConfig -Scope 'executors'
    if ($slave_redownload) {
        Get-SlaveAgent
        Stop-Service -Name $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
        Start-Service -Name $services["jenkins-slave"]["service"]
    }
}

function Start-RelationJoinedHook {
    $slavehost = $env:computername
    $config_executors = Get-JujuCharmConfig -Scope 'executors'
    if (!$config_executors) {
        $executors = Get-WmiObject -Class Win32_ComputerSystem | select -ExpandProperty "NumberOfLogicalProcessors"
    }
    else {
        $executors = Get-JujuCharmConfig -Scope 'executors'
    }

    $config_labels = Get-JujuCharmConfig -Scope 'labels'
    if ($config_labels) {
        $labels = $config_labels
    }
    else {
        $labels=(Get-WmiObject -class Win32_OperatingSystem).Caption
    }

    $settings = @{
	'slavehost' = $slavehost
	'executors' = $executors
	'labels' = $labels
	}
	$rids = Get-JujuRelationIds -Relation 'slave'
	Set-JujuRelation -RelationId $rids $settings
    juju-log.exe "Running relationName joined hook."
}


function Start-RelationChangedHook {
#    Start-ConfigTemplate
    $services = Get-CharmServices
    $slaveservice = Get-Service $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
    if (!$slaveservice) {
    Get-SlaveAgent
    Start-CopyTemplates
    Start-ConfigTemplate
    Start-SetJenkinsService
    }
    else {
        Stop-Service -Name $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
        Start-ConfigTemplate
    }
    Start-Service -Name $services["jenkins-slave"]["service"]
}

function Start-RelationDepartedHook {
    $services = Get-CharmServices
    $slaveservice = Get-Service $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
    $slave_exe = $INSTALL_DIR + "\jenkins-slave.exe"
    if(!$slaveservice) {
        juju-log.exe "Jenkins Slave service not found"
    }
    Stop-Service -Name $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
    & $slave_exe uninstall $services["jenkins-slave"]["service"]
}

function Start-RelationBrokenHook {
    CheckRemoveDir $INSTALL_DIR
}

function Start-StartHook {
    $services = Get-CharmServices
    $slaveservice = Get-Service $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
    if ($slaveservice.Status -eq "Stopped") {
        Start-Service -Name $services["jenkins-slave"]["service"]
    }
}

function Start-StopHook {
    $services = Get-CharmServices
    $slaveservice = Get-Service $services["jenkins-slave"]["service"] -ErrorAction SilentlyContinue
    if ($slaveservice.Status -eq "Running") {
        Stop-Service -Name $services["jenkins-slave"]["service"]
    }
}