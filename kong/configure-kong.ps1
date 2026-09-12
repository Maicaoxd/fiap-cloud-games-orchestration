[CmdletBinding()]
param(
    [string]$AdminUrl = "http://localhost:8001",
    [string]$JwtSecret = $env:FCG_JWT_SECRET,
    [ValidateRange(1, 65535)]
    [int]$UpstreamPort = 8080,
    [ValidateRange(1, 600)]
    [int]$WaitTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AdminUrl = $AdminUrl.TrimEnd("/")

function Invoke-KongRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Get", "Post", "Patch", "Delete")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [hashtable]$Body,

        [switch]$AllowNotFound
    )

    $request = @{
        Method = $Method
        Uri = "$AdminUrl$Path"
        TimeoutSec = 15
    }

    if ($null -ne $Body) {
        $request.ContentType = "application/json"
        $request.Body = $Body | ConvertTo-Json -Depth 10
    }

    try {
        return Invoke-RestMethod @request
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($AllowNotFound -and $statusCode -eq 404) {
            return $null
        }

        $details = if ($null -ne $_.ErrorDetails) { $_.ErrorDetails.Message } else { $null }
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $_.Exception.Message
        }

        throw "Kong Admin API retornou erro em $Method $Path (HTTP $statusCode): $details"
    }
}

function Wait-Kong {
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)

    do {
        try {
            $status = Invoke-RestMethod -Method Get -Uri "$AdminUrl/status" -TimeoutSec 5
            if ($status.database.reachable -eq $true) {
                Write-Host "Kong disponivel e conectado ao PostgreSQL."
                return
            }
        }
        catch {
            # O Kong pode recusar conexoes enquanto conclui a inicializacao.
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Kong nao ficou disponivel em $AdminUrl dentro de $WaitTimeoutSeconds segundos."
}

function Set-KongService {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Definition
    )

    $existing = Invoke-KongRequest -Method Get -Path "/services/$($Definition.Name)" -AllowNotFound
    $body = @{
        name = $Definition.Name
        protocol = "http"
        host = $Definition.Host
        port = $Definition.Port
        path = $Definition.Path
    }

    if ($null -eq $existing) {
        $service = Invoke-KongRequest -Method Post -Path "/services" -Body $body
        Write-Host "Service criado: $($Definition.Name)"
        return $service
    }

    $service = Invoke-KongRequest -Method Patch -Path "/services/$($Definition.Name)" -Body $body
    Write-Host "Service atualizado: $($Definition.Name)"
    return $service
}

function Set-KongRoute {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Definition,

        [Parameter(Mandatory)]
        [object]$Service
    )

    $existing = Invoke-KongRequest -Method Get -Path "/routes/$($Definition.Name)" -AllowNotFound
    $body = @{
        name = $Definition.Name
        paths = [object[]]$Definition.Paths
        protocols = @("http", "https")
        strip_path = $Definition.StripPath
        regex_priority = $Definition.RegexPriority
        preserve_host = $false
        path_handling = "v0"
        service = @{ id = $Service.id }
    }

    if (@($Definition.Methods).Count -eq 0) {
        $body.methods = $null
    }
    else {
        $body.methods = [object[]]$Definition.Methods
    }

    if ($null -eq $existing) {
        $route = Invoke-KongRequest -Method Post -Path "/routes" -Body $body
        Write-Host "Route criada: $($Definition.Name)"
        return $route
    }

    $route = Invoke-KongRequest -Method Patch -Path "/routes/$($Definition.Name)" -Body $body
    Write-Host "Route atualizada: $($Definition.Name)"
    return $route
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Entity,

        [Parameter(Mandatory)]
        [string]$Field,

        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected
    )

    if ([string]$Actual -ne [string]$Expected) {
        throw "$Entity possui $Field incorreto. Esperado '$Expected', recebido '$Actual'."
    }
}

function Set-KongPlugin {
    param([object]$Route, [string]$Name, [hashtable]$Config)

    $plugins = @( (Invoke-KongRequest -Method Get -Path "/routes/$($Route.id)/plugins").data |
        Where-Object { $_.name -eq $Name -and $null -eq $_.consumer -and $null -eq $_.service })
    if ($plugins.Count -gt 1) {
        throw "Mais de um plugin $Name encontrado em $($Route.name). Resolva a duplicidade antes de continuar."
    }
    $body = @{ name = $Name; enabled = $true; config = $Config; route = @{ id = $Route.id } }
    if ($plugins.Count -eq 0) {
        Invoke-KongRequest -Method Post -Path "/plugins" -Body $body | Out-Null
    }
    else {
        Invoke-KongRequest -Method Patch -Path "/plugins/$($plugins[0].id)" -Body $body | Out-Null
    }
}

function Set-KongJwtIssuer {
    $consumer = Invoke-KongRequest -Method Get -Path "/consumers/fiap-cloud-games" -AllowNotFound
    if ($null -eq $consumer) {
        if ([string]::IsNullOrWhiteSpace($JwtSecret)) {
            throw "Informe -JwtSecret ou FCG_JWT_SECRET para configurar um banco novo."
        }
        $consumer = Invoke-KongRequest -Method Post -Path "/consumers" -Body @{ username = "fiap-cloud-games"; custom_id = "fiap-cloud-games" }
    }
    $credentials = @((Invoke-KongRequest -Method Get -Path "/consumers/$($consumer.id)/jwt").data |
        Where-Object { $_.key -eq "FiapCloudGames" })
    if ($credentials.Count -gt 1) { throw "Credenciais JWT duplicadas para FiapCloudGames." }
    if ($credentials.Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($JwtSecret)) { throw "Informe -JwtSecret ou FCG_JWT_SECRET para criar a credencial JWT." }
        Invoke-KongRequest -Method Post -Path "/consumers/$($consumer.id)/jwt" -Body @{
            key = "FiapCloudGames"; algorithm = "HS256"; secret = $JwtSecret
        } | Out-Null
    }
    else {
        Assert-Equal -Entity "Credencial FiapCloudGames" -Field "algorithm" -Actual $credentials[0].algorithm -Expected "HS256"
        if (-not [string]::IsNullOrWhiteSpace($JwtSecret) -and $credentials[0].secret -cne $JwtSecret) {
            throw "O segredo informado difere da credencial existente. Rotacao exige uma acao explicita."
        }
    }
    # Nunca imprime o segredo nem altera credenciais existentes automaticamente.
}

function Assert-ArrayEqual {
    param(
        [Parameter(Mandatory)]
        [string]$Entity,

        [Parameter(Mandatory)]
        [string]$Field,

        [AllowNull()]
        [object[]]$Actual,

        [AllowNull()]
        [object[]]$Expected
    )

    $actualValue = (@($Actual) | ForEach-Object { [string]$_ } | Sort-Object) -join ","
    $expectedValue = (@($Expected) | ForEach-Object { [string]$_ } | Sort-Object) -join ","

    if ($actualValue -ne $expectedValue) {
        throw "$Entity possui $Field incorreto. Esperado '$expectedValue', recebido '$actualValue'."
    }
}

$serviceDefinitions = @(
    [pscustomobject]@{
        Name = "users-api"
        Host = "users-api"
        Port = $UpstreamPort
        Path = "/api"
    },
    [pscustomobject]@{
        Name = "catalog-api"
        Host = "catalog-api"
        Port = $UpstreamPort
        Path = "/api"
    }
)

$routeDefinitions = @(
    [pscustomobject]@{
        Name = "identity-public-registration"
        ServiceName = "users-api"
        Paths = @('~/identity/users/?$')
        Methods = @("POST")
        StripPath = $false
        RegexPriority = 100
        UpstreamUri = "/api/users"
    },
    [pscustomobject]@{
        Name = "identity-public-login"
        ServiceName = "users-api"
        Paths = @('~/identity/auth/login/?$')
        Methods = @("POST")
        StripPath = $false
        RegexPriority = 100
        UpstreamUri = "/api/auth/login"
    },
    [pscustomobject]@{
        Name = "identity-public-forgot-password"
        ServiceName = "users-api"
        Paths = @('~/identity/auth/forgot-password/?$')
        Methods = @("POST")
        StripPath = $false
        RegexPriority = 100
        UpstreamUri = "/api/auth/forgot-password"
    },
    [pscustomobject]@{
        Name = "identity-protected"
        ServiceName = "users-api"
        Paths = @('~/identity(?:/|$)')
        Methods = @()
        StripPath = $true
        RegexPriority = 0
        UpstreamUri = $null
    },
    [pscustomobject]@{
        Name = "catalog-protected"
        ServiceName = "catalog-api"
        Paths = @('~/catalog(?:/|$)')
        Methods = @()
        StripPath = $true
        RegexPriority = 0
        UpstreamUri = $null
    }
)

Wait-Kong
Set-KongJwtIssuer

$inheritedJwt = @((Invoke-KongRequest -Method Get -Path "/plugins").data | Where-Object {
    $_.name -eq "jwt" -and $_.enabled -and $null -eq $_.route
})
if ($inheritedJwt.Count -gt 0) {
    throw "JWT global ou em Service/Consumer pode afetar as rotas publicas. Revise esse escopo antes de aplicar."
}

$servicesByName = @{}
foreach ($definition in $serviceDefinitions) {
    $servicesByName[$definition.Name] = Set-KongService -Definition $definition
}

foreach ($definition in $routeDefinitions) {
    $route = Set-KongRoute -Definition $definition -Service $servicesByName[$definition.ServiceName]
    if ($null -ne $definition.UpstreamUri) {
        $jwtPlugins = @((Invoke-KongRequest -Method Get -Path "/routes/$($route.id)/plugins").data | Where-Object { $_.name -eq "jwt" })
        if ($jwtPlugins.Count -gt 0) { throw "Route publica $($route.name) possui JWT. Revise o escopo antes de continuar." }
        Set-KongPlugin -Route $route -Name "request-transformer" -Config @{ replace = @{ uri = $definition.UpstreamUri } }
    }
    else {
        Set-KongPlugin -Route $route -Name "jwt" -Config @{
            key_claim_name = "iss"
            claims_to_verify = @("exp")
            secret_is_base64 = $false
            header_names = @("authorization")
            uri_param_names = @()
            cookie_names = @()
            anonymous = $null
            run_on_preflight = $true
        }
    }
}

# Remove apenas a regra legada conhecida, depois de preparar os novos destinos.
$legacyPublic = Invoke-KongRequest -Method Get -Path "/routes/identity-public" -AllowNotFound
if ($null -ne $legacyPublic) {
    Invoke-KongRequest -Method Delete -Path "/routes/identity-public" | Out-Null
    Write-Host "Route publica generica identity-public removida."
}

Write-Host "Validando configuracao aplicada..."

foreach ($definition in $serviceDefinitions) {
    $service = Invoke-KongRequest -Method Get -Path "/services/$($Definition.Name)"
    Assert-Equal -Entity "Service $($definition.Name)" -Field "protocol" -Actual $service.protocol -Expected "http"
    Assert-Equal -Entity "Service $($definition.Name)" -Field "host" -Actual $service.host -Expected $definition.Host
    Assert-Equal -Entity "Service $($definition.Name)" -Field "port" -Actual $service.port -Expected $definition.Port
    Assert-Equal -Entity "Service $($definition.Name)" -Field "path" -Actual $service.path -Expected $definition.Path
    $servicesByName[$definition.Name] = $service
}

$verifiedRoutes = foreach ($definition in $routeDefinitions) {
    $route = Invoke-KongRequest -Method Get -Path "/routes/$($Definition.Name)"
    Assert-ArrayEqual -Entity "Route $($definition.Name)" -Field "paths" -Actual $route.paths -Expected $definition.Paths
    Assert-ArrayEqual -Entity "Route $($definition.Name)" -Field "methods" -Actual $route.methods -Expected $definition.Methods
    Assert-Equal -Entity "Route $($definition.Name)" -Field "strip_path" -Actual $route.strip_path -Expected $definition.StripPath
    Assert-Equal -Entity "Route $($definition.Name)" -Field "regex_priority" -Actual $route.regex_priority -Expected $definition.RegexPriority
    Assert-Equal -Entity "Route $($definition.Name)" -Field "service" -Actual $route.service.id -Expected $servicesByName[$definition.ServiceName].id
    $plugins = @((Invoke-KongRequest -Method Get -Path "/routes/$($route.id)/plugins").data)
    if ($null -ne $definition.UpstreamUri) {
        $jwt = @($plugins | Where-Object { $_.name -eq "jwt" })
        if ($jwt.Count -ne 0) { throw "Route publica $($route.name) possui plugin JWT." }
        $transformers = @($plugins | Where-Object { $_.name -eq "request-transformer" -and $_.enabled })
        if ($transformers.Count -ne 1) { throw "Route publica $($route.name) exige um request-transformer ativo." }
        Assert-Equal -Entity "Route $($route.name)" -Field "upstream_uri" -Actual $transformers[0].config.replace.uri -Expected $definition.UpstreamUri
    }
    else {
        $jwt = @($plugins | Where-Object { $_.name -eq "jwt" -and $_.enabled -and $null -eq $_.consumer -and $null -eq $_.service })
        if ($jwt.Count -ne 1) { throw "Route protegida $($route.name) exige exatamente um JWT ativo, sem restricao a Consumer." }
        Assert-Equal -Entity "JWT $($route.name)" -Field "key_claim_name" -Actual $jwt[0].config.key_claim_name -Expected "iss"
        Assert-ArrayEqual -Entity "JWT $($route.name)" -Field "claims_to_verify" -Actual $jwt[0].config.claims_to_verify -Expected @("exp")
        Assert-ArrayEqual -Entity "JWT $($route.name)" -Field "uri_param_names" -Actual $jwt[0].config.uri_param_names -Expected @()
        Assert-ArrayEqual -Entity "JWT $($route.name)" -Field "cookie_names" -Actual $jwt[0].config.cookie_names -Expected @()
        Assert-ArrayEqual -Entity "JWT $($route.name)" -Field "header_names" -Actual $jwt[0].config.header_names -Expected @("authorization")
        Assert-Equal -Entity "JWT $($route.name)" -Field "anonymous" -Actual $jwt[0].config.anonymous -Expected $null
        Assert-Equal -Entity "JWT $($route.name)" -Field "secret_is_base64" -Actual $jwt[0].config.secret_is_base64 -Expected $false
    }
    $route
}

Write-Host "Configuracao validada: $($serviceDefinitions.Count) Services e $(@($verifiedRoutes).Count) Routes gerenciados."

[pscustomobject]@{
    Services = @($serviceDefinitions | ForEach-Object {
        $service = $servicesByName[$_.Name]
        [pscustomobject]@{
            Name = $service.name
            Id = $service.id
            Upstream = "$($service.protocol)://$($service.host):$($service.port)$($service.path)"
        }
    })
    Routes = @($verifiedRoutes | ForEach-Object {
        [pscustomobject]@{
            Name = $_.name
            Id = $_.id
            Paths = $_.paths
            Methods = $_.methods
            StripPath = $_.strip_path
        }
    })
} | ConvertTo-Json -Depth 6
