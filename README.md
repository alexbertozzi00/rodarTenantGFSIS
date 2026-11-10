# rodarTenantGFSIS

Roda uma query ou um arquivo `.sql` em todos os bancos Postgres cujo nome começa com `gestaofacil_`. Feito para aplicar migrations em todos os tenants de uma vez, sem rodar banco por banco na mão.

Se der erro em um banco, ele sofre rollback e a execução segue para o próximo. No final sai o resumo com os bancos que falharam.

## Arquivos

| Arquivo | Para que serve |
| --- | --- |
| `rodarTenantGFSIS.cmd` | Dois cliques para abrir o menu. |
| `rodarTenantGFSIS.ps1` | O script. Os dois arquivos precisam ficar na mesma pasta. |
| `.env` | Configuração de conexão, prefixo e paralelismo (opcional). |
| `.env.example` | Modelo do `.env`, com todas as chaves aceitas. |
| `resultado-AAAAMMDD-HHMMSS.txt` / `.csv` | Resultados que você escolher salvar pelo menu. |

## Requisitos

- Windows com PowerShell 5.1 ou superior.
- `psql` no PATH (testado com o cliente do PostgreSQL 12).
- Acesso ao servidor. Padrão: `localhost:5432`, usuário `postgres`. Se o servidor reclamar de senha e ela não estiver no `.env`, em `pgpass.conf` ou em `PGPASSWORD`, o script pede uma única vez.

## Configuração (.env)

O arquivo `.env`, na mesma pasta do script, define os valores usados quando nada é passado por parâmetro. Ele é opcional: sem ele valem os padrões.

```
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=
PREFIXO=gestaofacil_
PARALELO=1
```

| Chave | Descrição | Padrão |
| --- | --- | --- |
| `PGHOST` | Servidor Postgres. | `localhost` |
| `PGPORT` | Porta. | `5432` |
| `PGUSER` | Usuário. | `postgres` |
| `PGPASSWORD` | Senha. Fica em texto puro; prefira deixar vazio. | vazio |
| `PREFIXO` | Prefixo dos bancos em que o script roda. | `gestaofacil_` |
| `PARALELO` | Quantos bancos rodam ao mesmo tempo. | `1` |

- Precedência: parâmetro da linha de comando, depois `.env`, depois variável de ambiente, depois o padrão.
- Linhas iniciadas com `#` e chaves sem valor são ignoradas. O valor pode vir entre aspas.
- A senha do `.env` vale só durante a execução do script.
- O `.env` desta pasta está com `PARALELO=3`. A linha de status do menu mostra o usuário, os bancos selecionados e o paralelismo em uso.

## Menu

Abra pelo `rodarTenantGFSIS.cmd` ou rode o `.ps1` sem parâmetros.

```
=== Tenants 'gestaofacil_*' em localhost:5432 ===
Usuario: postgres | Bancos: todos (36) | Em paralelo: 3
1 - Rodar query
2 - Consultar bancos afetados
3 - Escolher bancos
4 - Repetir a ultima query nos bancos com erro (0)
5 - Definir quantos bancos rodam em paralelo
6 - Simular query (roda em todos e desfaz, sem gravar nada)
0 - Sair
```

### 1 - Rodar query

Há três formas de informar o SQL:

- Copie a query (Ctrl+C) e pressione Enter sem colar nada: o script usa o que está copiado. É a forma mais segura para queries de várias linhas.
- Cole no terminal (Ctrl+V) e pressione Enter.
- Informe o caminho completo de um arquivo `.sql`.

O SQL é exibido inteiro antes da confirmação `(s/N)`. Confira se está completo antes de responder `s`.

Ao terminar, o script pergunta se quer salvar o resultado. O arquivo é gravado nesta pasta.

### 2 - Consultar bancos afetados

Lista os bancos em que a próxima execução vai rodar (todos, ou os escolhidos na opção 3).

### 3 - Escolher bancos

Mostra os bancos numerados. Informe:

- `1,3,5-8` para rodar só nesses;
- `exceto 2,4` para rodar em todos menos esses;
- Enter para voltar a todos.

A seleção vale até ser alterada ou o menu ser fechado.

### 4 - Repetir nos bancos com erro

Depois de uma execução com falhas, roda a mesma query só nos bancos que falharam. Se a última execução foi uma simulação, repete como simulação.

### 5 - Paralelo

Define quantos bancos rodam ao mesmo tempo (1 a 16), só para a sessão atual do menu; o valor inicial vem do `.env`. Em paralelo, os bancos aparecem na ordem em que terminam.

Referência para escolher o valor:

- Migration leve (`add column`, `create table`): 4 a 8 já elimina a espera; mais que isso não muda nada perceptível.
- Operação pesada (update grande, criação de índice, alteração que reescreve tabela): 2 a 4, porque várias escritas simultâneas no mesmo disco se atrapalham.
- Acima do número de núcleos da máquina do Postgres o tempo total para de cair.

Cada tenant é um banco separado, então o paralelismo não cria disputa de lock entre eles; só aumenta a carga.

### 6 - Simular query

Roda o SQL em cada banco dentro de uma transação e dá rollback no final. Serve para ver se a migration passa em todos os tenants sem gravar nada.

- É recusada se o SQL contiver `COMMIT`, porque o commit gravaria as alterações antes do rollback.
- Valores de sequence consumidos por `nextval` não voltam com o rollback (comportamento do Postgres).
- Segura os mesmos locks da execução real enquanto roda em cada banco.

## Resultado

- **Consulta única** (`select`, `with`, `show`): o resultado de todos os bancos sai em uma tabela só, com a coluna `banco` na frente. Pode ser salvo em `.txt` ou `.csv` (separador `;`, abre direto no Excel).
- **Migration ou várias instruções**: a saída aparece em blocos, um por banco. Pode ser salva em `.txt`.

## Linha de comando

Passando a query ou `-Arquivo`, o script roda direto, sem menu e sem pedir confirmação.

```powershell
# arquivo de migration
.\rodarTenantGFSIS.ps1 -Arquivo C:\caminho\migration.sql

# simular antes de rodar de verdade
.\rodarTenantGFSIS.ps1 -Arquivo C:\caminho\migration.sql -Simular

# query direta, 4 bancos por vez
.\rodarTenantGFSIS.ps1 "alter table conta add column if not exists teste varchar(10)" -Paralelo 4

# consulta com resultado em CSV
.\rodarTenantGFSIS.ps1 "select count(*) from conta" -Csv C:\temp\contas.csv

# apenas alguns bancos
.\rodarTenantGFSIS.ps1 "select 1" -Bancos gestaofacil_cliente1,gestaofacil_cliente2

# listar os bancos afetados
.\rodarTenantGFSIS.ps1 -Listar
```

| Parâmetro | Descrição |
| --- | --- |
| `-Query` (ou primeiro argumento) | SQL a executar. |
| `-Arquivo` | Caminho de um `.sql` a executar. |
| `-Simular` | Roda e dá rollback no final, sem gravar nada. |
| `-Bancos` | Nomes dos bancos, separados por vírgula. Padrão: todos os do prefixo. |
| `-Paralelo` | Quantos bancos rodam ao mesmo tempo. Padrão: 1. |
| `-Saida` | Grava em `.txt` tudo o que foi exibido. |
| `-Csv` | Grava o resultado consolidado em `.csv` (só para consulta única). |
| `-Listar` | Apenas lista os bancos, sem executar nada. |
| `-SemTransacao` | Roda sem transação única, para comandos como `CREATE INDEX CONCURRENTLY`. Nesse modo um erro no meio não desfaz o que já rodou naquele banco. |
| `-Prefixo` | Prefixo dos bancos. Padrão: o do `.env`, ou `gestaofacil_`. |
| `-Servidor`, `-Porta`, `-Usuario` | Conexão. Padrão: os do `.env`, ou `localhost`, `5432`, `postgres`. |

Código de saída: `0` tudo certo, `1` algum banco falhou, `2` erro de uso ou de conexão.

Se o PowerShell bloquear a execução do script, use o `.cmd` ou rode com `powershell -ExecutionPolicy Bypass -File rodarTenantGFSIS.ps1 ...`.

## Problemas comuns

- **Falha de conexão:** o script mostra o erro do Postgres logo abaixo da mensagem dele (servidor fora do ar, porta errada, usuário ou senha inválidos). Confira os valores do `.env`.

  ```
  Nao foi possivel conectar em localhost:5999 com o usuario postgres.
  psql: error: could not connect to server: Connection refused
  ```

- **Query colada apareceu cortada:** responda `n` na confirmação e use a outra forma: copie a query (Ctrl+C), escolha a opção e pressione Enter sem colar.
- **Simulação recusada:** o SQL contém `COMMIT`. Remova o commit para simular.
- **`psql nao encontrado no PATH`:** adicione a pasta `bin` do PostgreSQL ao PATH.

## Observações

- Cada banco roda em transação própria: ou a migration entra inteira naquele banco, ou não entra.
- Arquivos `.sql` em UTF-8 ou ISO-8859-1 são detectados automaticamente.
- A saída de cada banco aparece quando ele termina, não linha a linha durante a execução.
