<#
.SYNOPSIS
    Roda uma query ou um arquivo .sql em todos os bancos cujo nome comeca com o prefixo informado.

.DESCRIPTION
    Sem parametros abre um menu interativo. Com parametros roda direto.
    Cada banco roda em uma transacao propria: se der erro, aquele banco sofre rollback e a execucao
    segue para o proximo. No final mostra o resumo com os bancos que falharam.
    Quando o SQL e uma unica consulta (select/with/show), o resultado de todos os bancos sai em uma
    tabela unica com a coluna "banco".

.EXAMPLE
    .\rodarTenantGFSIS.ps1

.EXAMPLE
    .\rodarTenantGFSIS.ps1 -Arquivo C:\caminho\migration.sql -Paralelo 4

.EXAMPLE
    .\rodarTenantGFSIS.ps1 "select count(*) from conta" -Csv C:\temp\contas.csv

.EXAMPLE
    .\rodarTenantGFSIS.ps1 "alter table conta add column if not exists teste varchar(10)" -Bancos gestaofacil_cliente1,gestaofacil_cliente2
#>
[CmdletBinding()]
param(
    # Query a executar (use -Arquivo para rodar um .sql)
    [Parameter(Position = 0)]
    [string]$Query,

    # Caminho de um arquivo .sql a executar
    [string]$Arquivo,

    [string]$Servidor = $(if ($env:PGHOST) { $env:PGHOST } else { 'localhost' }),
    [int]$Porta = $(if ($env:PGPORT) { [int]$env:PGPORT } else { 5432 }),
    [string]$Usuario = $(if ($env:PGUSER) { $env:PGUSER } else { 'postgres' }),
    [string]$Prefixo = 'gestaofacil_',

    # Roda apenas nestes bancos (nomes separados por virgula), em vez de todos os do prefixo
    [string[]]$Bancos,

    # Quantidade de bancos executados ao mesmo tempo
    [int]$Paralelo = 1,

    # Roda sem transacao unica (necessario para comandos como CREATE INDEX CONCURRENTLY)
    [switch]$SemTransacao,

    # Apenas lista os bancos que seriam afetados, sem executar nada
    [switch]$Listar,

    # Simulacao: roda o SQL em cada banco e desfaz tudo no final (rollback), sem gravar nada
    [switch]$Simular,

    # Caminho de um .txt onde gravar tudo o que for exibido na execucao
    [string]$Saida,

    # Caminho de um .csv onde gravar o resultado consolidado (somente quando o SQL for uma consulta)
    [string]$Csv
)

$psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
if (-not $psql) {
    Write-Host 'psql nao encontrado no PATH.' -ForegroundColor Red
    exit 2
}

# Configuracao opcional em um arquivo .env ao lado do script (linhas CHAVE=valor; # inicia comentario).
# Precedencia: parametro da linha de comando > .env > variavel de ambiente > padrao.
$senhaDoArquivo = $false
$arquivoEnv = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $arquivoEnv -PathType Leaf) {
    $configuracao = @{}
    foreach ($linhaEnv in [IO.File]::ReadAllLines($arquivoEnv)) {
        if ($linhaEnv -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $chaveEnv = $Matches[1].ToUpper()
            $valorEnv = $Matches[2]
            if ($valorEnv -match '^"(.*)"$' -or $valorEnv -match "^'(.*)'$") { $valorEnv = $Matches[1] }
            if ($valorEnv -ne '') { $configuracao[$chaveEnv] = $valorEnv }
        }
    }
    if ($configuracao.ContainsKey('PGHOST') -and -not $PSBoundParameters.ContainsKey('Servidor')) { $Servidor = $configuracao['PGHOST'] }
    if ($configuracao.ContainsKey('PGPORT') -and -not $PSBoundParameters.ContainsKey('Porta')) { $Porta = [int]$configuracao['PGPORT'] }
    if ($configuracao.ContainsKey('PGUSER') -and -not $PSBoundParameters.ContainsKey('Usuario')) { $Usuario = $configuracao['PGUSER'] }
    if ($configuracao.ContainsKey('PREFIXO') -and -not $PSBoundParameters.ContainsKey('Prefixo')) { $Prefixo = $configuracao['PREFIXO'] }
    if ($configuracao.ContainsKey('PARALELO') -and -not $PSBoundParameters.ContainsKey('Paralelo')) { $Paralelo = [int]$configuracao['PARALELO'] }
    if ($configuracao.ContainsKey('PGPASSWORD') -and -not $env:PGPASSWORD) {
        # Vale so durante esta execucao: e removida do ambiente ao sair.
        $env:PGPASSWORD = $configuracao['PGPASSWORD']
        $senhaDoArquivo = $true
    }
}

$conexao = @('-X', '-w', '-h', $Servidor, '-p', $Porta, '-U', $Usuario)
$interativo = -not [Console]::IsInputRedirected
$script:senhaInformada = $senhaDoArquivo
$script:codigoSaida = 0
$script:registro = New-Object System.Collections.Generic.List[string]

# Exibe a linha no terminal e guarda no registro da execucao (usado para gravar o .txt).
function Registrar([string]$Texto, [string]$Cor) {
    if ($Cor) { Write-Host $Texto -ForegroundColor $Cor } else { Write-Host $Texto }
    $script:registro.Add($Texto)
}

# Lista os bancos do servidor que comecam com o prefixo. Pede a senha uma unica vez, se necessario.
function Listar-Bancos {
    $sql = 'select datname from pg_database where not datistemplate and datallowconn order by datname'
    # 2>&1 traz as linhas de erro do psql junto com a saida, como ErrorRecord, para poder exibi-las.
    $retorno = @(& $psql @conexao -At -d postgres -c $sql 2>&1)
    $codigo = $LASTEXITCODE
    $erro = @($retorno | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_".TrimEnd() })
    # So pede a senha quando o servidor reclamou de senha; outros erros (servidor fora, usuario invalido) vao direto.
    if ($codigo -ne 0 -and -not $env:PGPASSWORD -and ($erro -join ' ') -match 'password|senha') {
        $segura = Read-Host "Senha do usuario $Usuario" -AsSecureString
        $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura))
        $script:senhaInformada = $true
        $retorno = @(& $psql @conexao -At -d postgres -c $sql 2>&1)
        $codigo = $LASTEXITCODE
        $erro = @($retorno | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_".TrimEnd() })
    }
    if ($codigo -ne 0) {
        $mensagem = "Nao foi possivel conectar em ${Servidor}:$Porta com o usuario $Usuario."
        if ($erro.Count -gt 0) { $mensagem += "`n" + (($erro | Where-Object { $_ }) -join "`n") }
        throw $mensagem
    }
    return @($retorno | Where-Object { $_ -is [string] -and $_ -and $_.StartsWith($Prefixo) })
}

# UTF8 quando o arquivo for UTF-8 valido; caso contrario LATIN1 (ISO-8859-1).
function Detectar-Codificacao([string]$Caminho) {
    try {
        [void](New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($Caminho))
        return 'UTF8'
    } catch {
        return 'LATIN1'
    }
}

# Verdadeiro quando o SQL e uma unica consulta, cujo resultado pode ser consolidado em uma tabela.
function Testar-Consulta([string]$Sql) {
    $limpo = [regex]::Replace($Sql, '(?s)/\*.*?\*/', ' ')
    $limpo = [regex]::Replace($limpo, '--[^\r\n]*', ' ')
    $limpo = $limpo.Trim().TrimEnd(';').Trim()
    return ($limpo -match '^(select|with|show|values|table)\b') -and ($limpo -notmatch ';')
}

# Converte a saida CSV do psql em objetos, com a coluna "banco" na frente.
function Converter-Csv([string]$Texto, [string]$Banco) {
    # Remove somente a quebra final: linha vazia no meio e um valor nulo em consulta de uma coluna so.
    $Texto = $Texto -replace '\r?\n\z', ''
    $quebra = $Texto.IndexOf("`n")
    if ($quebra -lt 0) { return }
    $cabecalho = $Texto.Substring(0, $quebra).TrimEnd("`r")
    $resto = $Texto.Substring($quebra + 1)

    # Nomes de coluna repetidos (ou iguais a "banco") recebem sufixo, senao a conversao falha.
    $bruto = $cabecalho | ConvertFrom-Csv -Header (1..300 | ForEach-Object { "c$_" })
    $nomes = @()
    $vistos = @{ 'banco' = 1 }
    foreach ($propriedade in $bruto.PSObject.Properties) {
        if ($null -eq $propriedade.Value) { break }
        $nome = $propriedade.Value
        if ($vistos.ContainsKey($nome)) {
            $sufixo = 2
            while ($vistos.ContainsKey("${nome}_$sufixo")) { $sufixo++ }
            $nome = "${nome}_$sufixo"
        }
        $vistos[$nome] = 1
        $nomes += $nome
    }

    # Com uma coluna so e sem aspas, cada linha e um valor (o ConvertFrom-Csv descartaria as vazias).
    if ($nomes.Count -eq 1 -and -not $resto.Contains('"')) {
        foreach ($valor in ($resto -split "`r?`n")) {
            [pscustomobject]([ordered]@{ banco = $Banco; $nomes[0] = $valor })
        }
        return
    }

    $resto | ConvertFrom-Csv -Header $nomes | ForEach-Object {
        $linha = [ordered]@{ banco = $Banco }
        foreach ($nome in $nomes) { $linha[$nome] = $_.$nome }
        [pscustomobject]$linha
    }
}

# Roda o SQL (texto ou arquivo) nos bancos informados, ate $Paralelo de cada vez.
# Devolve: Falhas (bancos com erro), Consolidado (se o resultado virou tabela unica) e Linhas (as linhas da tabela).
# Com $Simulacao, cada banco roda dentro de BEGIN ... ROLLBACK: mostra se o SQL passa, sem gravar nada.
function Executar-Sql([string[]]$Alvos, [string]$TextoSql, [string]$CaminhoSql, [bool]$Simulacao) {
    $script:registro = New-Object System.Collections.Generic.List[string]
    $temporarios = New-Object System.Collections.Generic.List[string]

    # Query digitada/colada vai para um arquivo temporario, para nao depender do escape de aspas.
    if ($TextoSql) {
        $arquivoSql = [IO.Path]::GetTempFileName()
        $temporarios.Add($arquivoSql)
        [IO.File]::WriteAllText($arquivoSql, $TextoSql, (New-Object Text.UTF8Encoding($false)))
        $codificacao = 'UTF8'
        $descricao = $TextoSql
    } else {
        $arquivoSql = (Resolve-Path -LiteralPath $CaminhoSql).Path
        $codificacao = Detectar-Codificacao $arquivoSql
        $descricao = "Arquivo: $arquivoSql"
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    if ($codificacao -eq 'LATIN1') { $encoding = [Text.Encoding]::GetEncoding(28591) }
    $conteudo = $TextoSql
    if (-not $TextoSql) { $conteudo = [IO.File]::ReadAllText($arquivoSql, $encoding) }

    $consolidar = Testar-Consulta $conteudo
    $argumentos = ($conexao -join ' ') + ' -v ON_ERROR_STOP=1'
    if ($Simulacao) {
        # Um COMMIT dentro do SQL gravaria as alteracoes antes do rollback final.
        $semComentarios = [regex]::Replace([regex]::Replace($conteudo, '(?s)/\*.*?\*/', ' '), '--[^\r\n]*', ' ')
        if ($SemTransacao -or $semComentarios -match '\bcommit\b') {
            foreach ($temporario in $temporarios) { Remove-Item -LiteralPath $temporario -ErrorAction SilentlyContinue }
            throw 'Simulacao recusada: o SQL contem COMMIT ou foi pedido -SemTransacao, entao nao ha como garantir o rollback.'
        }
        $argumentos += " -c BEGIN -f `"$arquivoSql`" -c ROLLBACK"
    } else {
        $argumentos += " -f `"$arquivoSql`""
        if (-not $SemTransacao) { $argumentos += ' --single-transaction' }
    }
    if ($consolidar) { $argumentos += ' --csv' }

    if ($Simulacao) {
        Registrar 'SIMULACAO: cada banco roda e sofre rollback no final. Nada sera gravado.' 'Yellow'
        $script:registro.Add('')
    }
    $script:registro.Add("Execucao em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') - ${Servidor}:$Porta - $($Alvos.Count) banco(s)")
    $script:registro.Add('--- SQL ---')
    $script:registro.Add($descricao)
    $script:registro.Add('---')
    $script:registro.Add('')

    $limite = [Math]::Max(1, $Paralelo)
    $fila = New-Object System.Collections.Generic.Queue[string]
    foreach ($alvo in $Alvos) { $fila.Enqueue($alvo) }
    $ativos = New-Object System.Collections.Generic.List[object]
    $falhas = New-Object System.Collections.Generic.List[string]
    $linhasPorBanco = @{}
    $concluidos = 0
    $encodingAnterior = $env:PGCLIENTENCODING
    $env:PGCLIENTENCODING = $codificacao
    try {
        while ($fila.Count -gt 0 -or $ativos.Count -gt 0) {
            while ($fila.Count -gt 0 -and $ativos.Count -lt $limite) {
                $banco = $fila.Dequeue()
                $arquivoSaida = [IO.Path]::GetTempFileName()
                $arquivoErro = [IO.Path]::GetTempFileName()
                $temporarios.Add($arquivoSaida)
                $temporarios.Add($arquivoErro)
                $processo = Start-Process -FilePath $psql -ArgumentList "$argumentos -d $banco" -NoNewWindow -PassThru `
                    -RedirectStandardOutput $arquivoSaida -RedirectStandardError $arquivoErro
                # Sem guardar o handle, o ExitCode nao fica disponivel depois que o processo termina.
                $null = $processo.Handle
                $ativos.Add(@{ Banco = $banco; Processo = $processo; Saida = $arquivoSaida; Erro = $arquivoErro })
            }

            foreach ($ativo in $ativos.ToArray()) {
                if (-not $ativo.Processo.HasExited) { continue }
                $ativo.Processo.WaitForExit()
                [void]$ativos.Remove($ativo)
                $concluidos++
                $banco = $ativo.Banco
                $sucesso = $ativo.Processo.ExitCode -eq 0
                $saidaBruta = [IO.File]::ReadAllText($ativo.Saida, $encoding)
                if ($Simulacao) {
                    # Tira da saida as linhas do BEGIN/ROLLBACK que envolvem a simulacao.
                    $saidaBruta = $saidaBruta -replace '\ABEGIN\r?\n', '' -replace '(?<=\A|\n)ROLLBACK\r?\n\z', ''
                }
                $saida = $saidaBruta.TrimEnd()
                $erro = [IO.File]::ReadAllText($ativo.Erro, $encoding).TrimEnd()
                $prefixoLinha = "[$concluidos/$($Alvos.Count)] $banco"

                if ($consolidar -and $sucesso) {
                    $linhas = @(Converter-Csv $saidaBruta $banco)
                    $linhasPorBanco[$banco] = $linhas
                    Registrar "${prefixoLinha}: $($linhas.Count) linha(s)" 'Cyan'
                } elseif ($consolidar) {
                    Registrar "${prefixoLinha}: ERRO" 'Red'
                } else {
                    Registrar $prefixoLinha 'Cyan'
                    if ($saida) { $saida -split "`r?`n" | ForEach-Object { Registrar $_ } }
                }
                if ($erro) { $erro -split "`r?`n" | ForEach-Object { Registrar $_ } }
                if (-not $sucesso) {
                    if (-not $consolidar) { Registrar "    ERRO em $banco (seguindo para o proximo)" 'Red' }
                    $falhas.Add($banco)
                }
            }
            if ($ativos.Count -gt 0) { Start-Sleep -Milliseconds 50 }
        }
    } finally {
        foreach ($ativo in $ativos) {
            if (-not $ativo.Processo.HasExited) { $ativo.Processo.Kill() }
        }
        $env:PGCLIENTENCODING = $encodingAnterior
        foreach ($temporario in $temporarios) { Remove-Item -LiteralPath $temporario -ErrorAction SilentlyContinue }
    }

    # Junta as linhas na ordem dos bancos, independente da ordem em que terminaram.
    $todasLinhas = New-Object System.Collections.Generic.List[object]
    foreach ($alvo in $Alvos) {
        if ($linhasPorBanco.ContainsKey($alvo)) {
            foreach ($linha in $linhasPorBanco[$alvo]) { $todasLinhas.Add($linha) }
        }
    }
    if ($consolidar) {
        Registrar ''
        if ($todasLinhas.Count -gt 0) {
            ($todasLinhas | Format-Table -AutoSize | Out-String -Width 4096).Trim("`r", "`n") -split "`r?`n" |
                ForEach-Object { Registrar $_.TrimEnd() }
            Registrar ''
            Registrar "Total: $($todasLinhas.Count) linha(s)."
        } else {
            Registrar 'Nenhuma linha retornada.'
        }
    }

    Registrar ''
    $corResumo = 'Green'
    if ($falhas.Count -gt 0) { $corResumo = 'Yellow' }
    $rotulo = 'Concluido'
    if ($Simulacao) { $rotulo = 'Simulacao concluida (nada foi gravado)' }
    Registrar "${rotulo}: $($Alvos.Count - $falhas.Count) ok, $($falhas.Count) com erro." $corResumo
    if ($falhas.Count -gt 0) {
        Registrar 'Bancos com erro:' 'Red'
        foreach ($falha in $falhas) { Registrar "    $falha" 'Red' }
    }

    return @{ Falhas = $falhas.ToArray(); Consolidado = $consolidar; Linhas = $todasLinhas.ToArray() }
}

# Grava em .txt tudo o que foi exibido na ultima execucao.
function Salvar-Txt([string]$Caminho) {
    [IO.File]::WriteAllLines($Caminho, $script:registro, (New-Object Text.UTF8Encoding($true)))
}

# Grava o resultado consolidado em .csv (separador ";", que e o que o Excel em portugues abre direto).
function Salvar-Csv([object[]]$Linhas, [string]$Caminho) {
    $Linhas | Export-Csv -LiteralPath $Caminho -Delimiter ';' -NoTypeInformation -Encoding UTF8
}

# Le o SQL do terminal. Um colar de varias linhas chega como varias linhas seguidas: le enquanto ainda
# houver entrada pendente no console, para tratar tudo como um unico SQL. Vazio usa a area de transferencia.
function Ler-Sql {
    Write-Host 'Cole a query (Ctrl+V, pode ter varias linhas) e pressione Enter.'
    Write-Host 'Enter sem colar nada usa o que estiver copiado (Ctrl+C).'
    $linhas = New-Object System.Collections.Generic.List[string]
    do {
        $linha = Read-Host
        if ($null -eq $linha) { break }
        $linhas.Add($linha)
        $temMais = $false
        if ($interativo) {
            Start-Sleep -Milliseconds 250
            $temMais = [Console]::KeyAvailable
        }
    } while ($temMais)
    $entrada = ($linhas -join "`n").Trim()
    if (-not $entrada) {
        $entrada = "$(Get-Clipboard -Raw)".Trim()
    }
    return $entrada
}

# Descarta sobra de teclas para a proxima pergunta nao ser respondida por resto de texto colado.
function Limpar-Teclas {
    while ($interativo -and [Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
}

# Roda pelo menu e, ao concluir, oferece gravar o resultado. Devolve os bancos que falharam.
function Rodar-PeloMenu([string[]]$Alvos, [hashtable]$Sql) {
    try {
        $resultado = Executar-Sql $Alvos $Sql.Texto $Sql.Caminho $Sql.Simular
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        return
    }
    Limpar-Teclas
    $carimbo = 'resultado-{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $temTabela = $resultado.Consolidado -and $resultado.Linhas.Count -gt 0
    if ($temTabela) {
        $salvar = Read-Host 'Salvar o resultado? (t = .txt, c = .csv, Enter = nao)'
    } else {
        $salvar = Read-Host 'Salvar o resultado em .txt? (s/N)'
    }
    if ($salvar -match '^[cC]' -and $temTabela) {
        $destino = Join-Path $PSScriptRoot "$carimbo.csv"
        Salvar-Csv $resultado.Linhas $destino
        Write-Host "Resultado salvo em: $destino" -ForegroundColor Green
    } elseif ($salvar -match '^[sStT]') {
        $destino = Join-Path $PSScriptRoot "$carimbo.txt"
        Salvar-Txt $destino
        Write-Host "Resultado salvo em: $destino" -ForegroundColor Green
    }
    return $resultado.Falhas
}

# Fluxo principal: modo direto (com parametros) ou menu interativo (sem parametros).
function Principal {
    $todos = @(Listar-Bancos)
    if ($todos.Count -eq 0) {
        Write-Host "Nenhum banco com prefixo '$Prefixo' em ${Servidor}:$Porta." -ForegroundColor Yellow
        return
    }

    # Selecao inicial vinda de -Bancos (no modo -File a lista chega como um texto unico com virgulas).
    $selecionados = $null
    if ($Bancos) {
        $pedidos = @($Bancos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $desconhecidos = @($pedidos | Where-Object { $todos -notcontains $_ })
        if ($desconhecidos.Count -gt 0) {
            Write-Host "Banco(s) nao encontrado(s): $($desconhecidos -join ', ')" -ForegroundColor Red
            $script:codigoSaida = 2
            return
        }
        $selecionados = @($todos | Where-Object { $pedidos -contains $_ })
    }

    $modoMenu = -not $Listar -and [string]::IsNullOrWhiteSpace($Query) -and [string]::IsNullOrWhiteSpace($Arquivo)
    if (-not $modoMenu) {
        $alvos = $todos
        if ($selecionados) { $alvos = $selecionados }
        if ($Listar) {
            $alvos | ForEach-Object { Write-Host $_ }
            Write-Host "$($alvos.Count) banco(s)."
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($Query) -and -not [string]::IsNullOrWhiteSpace($Arquivo)) {
            Write-Host 'Informe a query OU -Arquivo <caminho.sql> (apenas um dos dois).' -ForegroundColor Red
            $script:codigoSaida = 2
            return
        }
        if ($Arquivo -and -not (Test-Path -LiteralPath $Arquivo -PathType Leaf)) {
            Write-Host "Arquivo nao encontrado: $Arquivo" -ForegroundColor Red
            $script:codigoSaida = 2
            return
        }
        $resultado = Executar-Sql $alvos $Query $Arquivo $Simular.IsPresent
        if ($Saida) { Salvar-Txt $Saida }
        if ($Csv) {
            if ($resultado.Consolidado) {
                Salvar-Csv $resultado.Linhas $Csv
            } else {
                Write-Host 'CSV nao gerado: o SQL nao e uma consulta unica.' -ForegroundColor Yellow
            }
        }
        if ($resultado.Falhas.Count -gt 0) { $script:codigoSaida = 1 }
        return
    }

    # Menu interativo.
    $falhas = @()
    $ultimoSql = $null
    while ($true) {
        $alvos = $todos
        if ($selecionados) { $alvos = $selecionados }
        $descricaoAlvos = "todos ($($todos.Count))"
        if ($selecionados) { $descricaoAlvos = "$($selecionados.Count) de $($todos.Count) selecionado(s)" }

        Write-Host ''
        Write-Host "=== Tenants '$Prefixo*' em ${Servidor}:$Porta ===" -ForegroundColor Cyan
        Write-Host "Usuario: $Usuario | Bancos: $descricaoAlvos | Em paralelo: $Paralelo" -ForegroundColor DarkGray
        Write-Host '1 - Rodar query'
        Write-Host '2 - Consultar bancos afetados'
        Write-Host '3 - Escolher bancos'
        Write-Host "4 - Repetir a ultima query nos bancos com erro ($($falhas.Count))"
        Write-Host '5 - Definir quantos bancos rodam em paralelo'
        Write-Host '6 - Simular query (roda em todos e desfaz, sem gravar nada)'
        Write-Host '0 - Sair'
        $opcao = Read-Host 'Opcao'
        if ($null -eq $opcao) { return }

        switch ($opcao.Trim()) {
            { $_ -eq '1' -or $_ -eq '6' } {
                $simular = $_ -eq '6'
                $entrada = Ler-Sql
                if (-not $entrada) {
                    Write-Host 'Nada informado.' -ForegroundColor Yellow
                    break
                }
                $sql = @{ Texto = $entrada; Caminho = $null; Simular = $simular }
                $titulo = '--- SQL a executar ---'
                if ($entrada -notmatch "`n") {
                    $caminho = $entrada.Trim('"')
                    # Um SQL com caracteres invalidos para caminho (ex.: "<") faz o Test-Path dar erro: nesse caso nao e arquivo.
                    $ehArquivo = $false
                    try { $ehArquivo = Test-Path -LiteralPath $caminho -PathType Leaf -ErrorAction Stop } catch { }
                    if ($ehArquivo) {
                        $sql = @{ Texto = $null; Caminho = $caminho; Simular = $simular }
                        $entrada = $caminho
                        $titulo = '--- Arquivo a executar ---'
                    }
                }
                Write-Host ''
                Write-Host $titulo -ForegroundColor Cyan
                Write-Host $entrada
                Write-Host '---' -ForegroundColor Cyan
                Limpar-Teclas
                $pergunta = "Rodar em $($alvos.Count) banco(s)? (s/N)"
                if ($simular) { $pergunta = "SIMULAR em $($alvos.Count) banco(s), sem gravar nada? (s/N)" }
                $confirmacao = Read-Host $pergunta
                if ($confirmacao -notmatch '^[sS]') {
                    Write-Host 'Cancelado.' -ForegroundColor Yellow
                    break
                }
                $ultimoSql = $sql
                $falhas = @(Rodar-PeloMenu $alvos $sql)
            }
            '2' {
                $alvos | ForEach-Object { Write-Host $_ }
                Write-Host "$($alvos.Count) banco(s)."
            }
            '3' {
                for ($i = 0; $i -lt $todos.Count; $i++) {
                    $marca = ' '
                    if ($alvos -contains $todos[$i]) { $marca = '*' }
                    Write-Host ('{0} {1,3} - {2}' -f $marca, ($i + 1), $todos[$i])
                }
                Write-Host "Informe os numeros (ex.: 1,3,5-8), 'exceto 2,4' para todos menos esses, ou Enter para todos."
                $resposta = Read-Host 'Bancos'
                if ([string]::IsNullOrWhiteSpace($resposta)) {
                    $selecionados = $null
                    Write-Host "Todos os $($todos.Count) bancos selecionados." -ForegroundColor Green
                    break
                }
                $excluir = $resposta -match '^\s*exceto\b'
                $resposta = $resposta -replace '^\s*exceto', ''
                $indices = @{}
                $valido = $true
                foreach ($parte in ($resposta -split '[,\s]+' | Where-Object { $_ })) {
                    if ($parte -match '^(\d+)-(\d+)$') {
                        [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { $indices[$_] = 1 }
                    } elseif ($parte -match '^\d+$') {
                        $indices[[int]$parte] = 1
                    } else {
                        $valido = $false
                    }
                }
                if ($valido) {
                    foreach ($indice in $indices.Keys) {
                        if ($indice -lt 1 -or $indice -gt $todos.Count) { $valido = $false }
                    }
                }
                if (-not $valido -or $indices.Count -eq 0) {
                    Write-Host 'Selecao invalida, nada foi alterado.' -ForegroundColor Yellow
                    break
                }
                $escolha = @()
                for ($i = 0; $i -lt $todos.Count; $i++) {
                    if ($indices.ContainsKey($i + 1) -ne $excluir) { $escolha += $todos[$i] }
                }
                if ($escolha.Count -eq 0) {
                    Write-Host 'A selecao ficaria vazia, nada foi alterado.' -ForegroundColor Yellow
                    break
                }
                $selecionados = $escolha
                Write-Host "$($selecionados.Count) banco(s) selecionado(s)." -ForegroundColor Green
            }
            '4' {
                if ($falhas.Count -eq 0 -or -not $ultimoSql) {
                    Write-Host 'Nao ha bancos com erro da ultima execucao.' -ForegroundColor Yellow
                    break
                }
                Write-Host ''
                Write-Host $(if ($ultimoSql.Simular) { '--- Repetir a SIMULACAO ---' } else { '--- Repetir ---' }) -ForegroundColor Cyan
                Write-Host $(if ($ultimoSql.Caminho) { $ultimoSql.Caminho } else { $ultimoSql.Texto })
                Write-Host '--- nos bancos ---' -ForegroundColor Cyan
                $falhas | ForEach-Object { Write-Host $_ }
                $confirmacao = Read-Host "Rodar em $($falhas.Count) banco(s)? (s/N)"
                if ($confirmacao -notmatch '^[sS]') {
                    Write-Host 'Cancelado.' -ForegroundColor Yellow
                    break
                }
                $falhas = @(Rodar-PeloMenu $falhas $ultimoSql)
            }
            '5' {
                $resposta = Read-Host 'Quantos bancos ao mesmo tempo (1 a 16)'
                if ($resposta -match '^\d+$' -and [int]$resposta -ge 1 -and [int]$resposta -le 16) {
                    $Paralelo = [int]$resposta
                } else {
                    Write-Host 'Valor invalido, nada foi alterado.' -ForegroundColor Yellow
                }
            }
            '0' { return }
            default { Write-Host 'Opcao invalida.' -ForegroundColor Yellow }
        }
    }
}

try {
    Principal
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $script:codigoSaida = 2
} finally {
    if ($script:senhaInformada) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
}
exit $script:codigoSaida
