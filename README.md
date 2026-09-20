# arca

Backup incremental do seu `$HOME` para o Google Drive, com **restic** + **rclone**.

Um script, um comando de instalação, agendamento automático e restauração
ponto-a-ponto no tempo. Feito para quem já tem espaço sobrando no Drive e não
quer pagar por mais um serviço de backup.

```
./install.sh        # interativo: instala, autoriza o Drive, agenda e roda o primeiro
arca backup         # incremental — é o que a cron chama todo dia
arca restore        # de volta
```

## Por que restic e rclone

O Google Drive montado pelo sistema (gvfs, no GNOME) serve para abrir um arquivo
e salvar de volta. Para backup ele falha: é lento com muitos arquivos pequenos,
não preserva permissões nem links, e sincronizador nenhum consegue detectar
mudança de forma confiável por cima dele — o resultado é recopiar tudo, toda vez.

O `rclone` fala a API do Google direto, sem passar por essa montagem. O `restic`
põe por cima o que falta num backup de verdade:

- **incremental com deduplicação** — os arquivos são cortados em blocos; depois
  do primeiro envio, só bloco novo sobe. Arquivo que não mudou nem é lido.
- **snapshots** — você volta ao estado de terça passada, não só ao último estado.
- **criptografia** — tudo é cifrado antes de sair da máquina. O Google guarda
  blocos opacos.
- **verificação** — `arca check` prova que o que está lá dentro ainda abre.

## Instalação

```bash
git clone https://github.com/mbergo/arca-backup.git ~/github/arca-backup
cd ~/github/arca-backup
./install.sh
```

O instalador pergunta, nesta ordem:

1. instalar `restic` e `rclone` se faltarem (apt, dnf, pacman, zypper ou brew)
2. autorizar o Google Drive — abre o navegador
3. pasta de destino dentro do Drive e o que fazer backup
4. senha do repositório — **ela é gerada e mostrada uma vez**
5. prioridade baixa (nice) e limite de upload
6. horário do backup diário na cron
7. rodar o primeiro backup completo

Para uma máquina nova, é só repetir isso: mesma senha, mesmo remote, e o `arca`
enxerga os snapshots antigos.

> **A senha é o backup.** Guarde fora da máquina — gerenciador de senhas, papel,
> outro computador. Sem ela não existe recuperação, por ninguém, de jeito nenhum.
> Ela fica em `~/.config/arca/password`, que é exatamente o arquivo que você
> perde quando o disco morre.

## Comandos

| Comando | O que faz |
|---|---|
| `arca full` | primeiro backup, completo |
| `arca backup` | incremental — o que a cron roda |
| `arca snapshots` | lista os pontos no tempo |
| `arca status` | último backup, tamanho ocupado no Drive |
| `arca check` | verifica integridade (lê 5% dos dados) |
| `arca find <padrão>` | procura um arquivo em todos os snapshots |
| `arca restore` | restaura (veja abaixo) |
| `arca mount [DIR]` | monta os backups como pasta e você navega |
| `arca drive-setup` | cria ou refaz o remote do Drive |
| `arca drive-mount [DIR]` | monta o Drive em si, em SO que não monta sozinho |
| `arca cron-install [HORA]` | agenda o diário |
| `arca cron-remove` | desagenda |
| `arca config` | mostra a configuração |

## Restauração

O caso comum, apagou um arquivo e quer de volta:

```bash
arca find "contrato*"                      # em que snapshot ele está?
arca restore --include ~/Documentos/contrato.pdf --target /tmp/volta
```

Navegar pelo backup como se fosse uma pasta, e copiar o que precisa na mão:

```bash
arca mount            # monta em /tmp/arca — ctrl+c desmonta
```

Restaurar de um ponto específico no tempo:

```bash
arca snapshots                             # pega o ID
arca restore --snapshot 4f2a1b9c --target /tmp/volta
```

**Máquina nova, disco zerado** — a ordem é esta:

```bash
# 1. instale restic e rclone
sudo apt install restic rclone

# 2. autorize o Drive
rclone config create gdrive drive scope=drive

# 3. aponte para o repositório e restaure
export RESTIC_REPOSITORY="rclone:gdrive:Backups/arca-SEUHOST"
restic snapshots                           # vai pedir a senha
restic restore latest --target /
```

Depois disso, `~/.config/arca/manifests/` tem a lista de programas que estavam
instalados (`Brewfile`, `apt-manual.txt`, `flatpak.txt`, `npm-global.txt`), para
refazer a máquina sem ficar lembrando o que tinha.

## O que fica de fora

O `lib/excludes.txt` deixa de fora o que é recriável ou o que atrapalha:

- **Locks dos navegadores** — `SingletonLock`, `SingletonSocket`, `SingletonCookie`
  (Chrome, Chromium, Brave, Edge) e `lock` / `.parentlock` (Firefox). São sockets
  e links quebrados; é neles que copiador de arquivo trava ou morre. Essa é a
  causa mais comum de "o backup emperrou no meio".
- **Caches** — `~/.cache`, `Cache`, `GPUCache`, `Code Cache`, miniaturas, lixeira.
  São a maior parte dos arquivos de um `$HOME` e não valem nada.
- **Dependências** — `node_modules`, `.venv`, `__pycache__`, `target/`, `.gradle`,
  `.m2/repository`, `.cargo/registry`, `.rustup`, `.nvm`.
- **Gerenciadores de pacote** — Homebrew (`/home/linuxbrew`) e afins. A receita
  vai em `manifests/Brewfile`; os binários, não.
- **Imagens de VM e container**, `.iso`, `.qcow2`, `.vdi`.

Edite `~/.config/arca/excludes.txt` à vontade; a sintaxe é a do restic
(`**/padrão` casa em qualquer nível).

## Prioridade baixa

Com `ARCA_NICE=1` (padrão), tudo roda em `nice -n 19` e `ionice -c3`: o backup
só usa CPU e disco que ninguém mais quer. Você pode trabalhar normalmente
durante o backup completo, inclusive.

Se a internet sofrer, use `ARCA_LIMIT_UPLOAD` na config (em KiB/s — `4096` é
4 MiB/s). Combinado com o horário da madrugada, o backup vira invisível.

## Credenciais próprias do Drive (opcional)

O rclone vem com credenciais OAuth compartilhadas por todo mundo que usa a
ferramenta, o que às vezes deixa lento. Para ter as suas:

1. https://console.cloud.google.com — crie um projeto
2. **APIs & Services → Library** → ative a **Google Drive API**
3. **OAuth consent screen** → tipo **External**, preencha o mínimo, e em
   **Test users** adicione o seu próprio e-mail
4. **Credentials → Create credentials → OAuth client ID** → tipo
   **Desktop app**
5. Copie o **Client ID** e o **Client secret**

Informe os dois quando o `install.sh` perguntar, ou depois:

```bash
arca drive-setup --client-id SEU_ID --client-secret SEU_SECRET
```

## Montar o Drive como pasta

Em sistema que não monta o Drive sozinho (o GNOME do Zorin/Ubuntu monta):

```bash
arca drive-mount ~/GoogleDrive     # em segundo plano
fusermount -u ~/GoogleDrive        # desmontar
```

Isso é conveniência para ver os arquivos. O backup **não** usa essa montagem.

## Retenção

O padrão guarda 7 diários, 4 semanais e 12 mensais. Snapshot fora dessa janela
é esquecido a cada execução, e o espaço é liberado de fato uma vez por semana
(`ARCA_PRUNE_DAY`, domingo por padrão), porque o `prune` é a parte pesada.

## Config

`~/.config/arca/config` — texto puro, edite quando quiser:

| Variável | Padrão | Para que serve |
|---|---|---|
| `ARCA_REPO` | `rclone:gdrive:Backups/arca-HOST` | onde fica o repositório |
| `ARCA_SOURCE` | `$HOME` | o que entra no backup |
| `ARCA_EXTRA_PATHS` | vazio | caminhos extras, ex: `"/etc /srv"` |
| `ARCA_NICE` | `1` | prioridade baixa de CPU e disco |
| `ARCA_LIMIT_UPLOAD` | `0` | limite de upload em KiB/s |
| `ARCA_KEEP_DAILY/WEEKLY/MONTHLY` | 7/4/12 | retenção |
| `ARCA_PRUNE_DAY` | `7` | dia da limpeza pesada (1=seg, 7=dom) |
| `ARCA_TRANSFERS` | `8` | uploads em paralelo |

## Licença

MIT.
