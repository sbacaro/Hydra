# Hydra Audio — Documento Fundacional do Projeto

> Planta-mestra única e autossuficiente. Este documento é a **referência completa** do
> projeto: arquitetura, escopo, modelo de dados, fluxo do usuário, design, licenciamento,
> roadmap e testes. Quem ler apenas este arquivo tem tudo o que precisa para construir o Hydra.
>
> Plataforma: macOS (Apple Silicon e Intel). Linguagem principal: Swift. Licença: GPL-3.0.
> Natureza: projeto de estudo, com intenção de distribuição gratuita futura.

---

## 1. Visão em uma frase

Um aplicativo macOS que une, num só ecossistema, um **patch bay de áudio**, **captura de áudio por aplicativo** e um **controlador AES67** que interopera com aparelhos Dante — tudo girando em torno de **uma única grade de patching**, com plugins **VST3** inseríveis no caminho do sinal.

## 2. Escopo e não-objetivos

**No escopo:**
- Rotear áudio entre aplicativos, placas físicas, rede (AES67) e cadeias de efeitos, tudo numa grade única.
- Capturar o áudio de aplicativos específicos (estilo Audio Hijack).
- Funcionar como uma placa de som virtual de grande contagem de canais (estilo Loopback).
- Interoperar com equipamentos Dante pela rede usando **AES67** (padrão aberto).
- Inserir plugins VST3 entre fonte e destino.

**Fora do escopo (não-objetivos), por decisão de projeto:**
- **Não** replicamos o protocolo proprietário do Dante nem tentamos aparecer como um "dispositivo Dante nativo" no Dante Controller. A interoperação com Dante é feita pela ponte aberta que o próprio ecossistema Dante oferece: o **modo AES67**. Isso é padrão, documentado e suficiente para enviar e receber áudio de aparelhos Dante.
- **Não** criamos múltiplas placas virtuais dinamicamente. Usamos **uma** placa de grande contagem de canais como backplane, e fazemos todo o roteamento por software sobre ela.

## 3. Decisões de fundação

| Tema | Decisão |
|---|---|
| Licença | **GPL-3.0** desde o primeiro arquivo |
| Onde roda | **MacBook host**, com **SIP ligado** (sem reduzir a segurança do sistema) |
| Camada de áudio | **Uma** placa virtual **256×256** (BlackHole customizado) como backplane |
| Roteamento | Feito pelo **motor do Hydra** por software, sobre o backplane |
| Rede | **AES67** (RTP/SDP/SAP/PTP — padrões abertos) |
| Distribuição | Gratuita, **creditando** os componentes de terceiros abertamente |

## 4. Princípios de engenharia

1. **Nada de fachada.** Se uma tela existe na UI, ela é funcional. Sem telas decorativas.
2. **Fonte única da verdade.** Constantes, tipos e identificadores ficam definidos em um só lugar, compartilhados por todos os módulos.
3. **Honestidade de estado.** A versão exibida e o CHANGELOG refletem exatamente o que compila e roda. Nada de "pronto" para o que é stub.
4. **Transparência de terceiros.** Componentes de código aberto são creditados abertamente (ver Seção 9). Dar nome de produto a um dispositivo é UX; ocultar a origem do componente não é permitido nem desejado.
5. **Cada fase entrega algo testável.** Todo marco do roadmap termina com um critério objetivo de "pronto", verificável no Mac.

---

## 5. Arquitetura

### 5.1 Camada de áudio — o backplane virtual 256×256

O Hydra usa **uma** placa de áudio virtual de 256 entradas × 256 saídas como "backplane" — um grande pool de canais onde todo o áudio transita. Essa placa é um **BlackHole customizado**:

- Construído a partir do código do BlackHole com `kNumber_Of_Channels=256`, e com nome e bundle ID de produto próprios (`kDriver_Name`, `kPlugIn_BundleID`, `kDevice_Name`), aparecendo no sistema como **"Hydra Virtual Soundcard"**.
- É um plugin **HAL de userspace** (AudioServerPlugIn), portanto **carrega no host sem desabilitar o SIP**. Para uso próprio, a assinatura local do Xcode (ad-hoc/time pessoal) basta; Developer ID + notarização só são necessários para distribuir o instalador a terceiros.
- Roda a **32-bit float** internamente (formato nativo do Core Audio), o que dá compatibilidade ampla e headroom.

**Característica essencial a entender:** essa placa é um **loopback reto** — o que é escrito no canal de saída N reaparece no canal de entrada N, sem nenhum roteamento interno. Ela é apenas o pool de 256 canais. **Toda a inteligência de patch vive no motor do Hydra** (Seção 5.2), não na placa.

**Transparência (resolve qualquer ambiguidade):** apresentar o dispositivo como "Hydra Virtual Soundcard" é apenas dar um nome de produto ao device — permitido pela GPL. O Hydra **credita abertamente** o BlackHole na tela *About / Acknowledgements* e em `THIRD_PARTY_NOTICES.md`, e distribui a licença GPL-3.0 e o código-fonte. Nomear o device é UX; creditar a base é obrigação e princípio.

**Cautela de performance:** 256 canais é o máximo prático; evitar combinar 256 canais com sample rates altíssimos. Alvo inicial: **48 kHz**.

### 5.2 O motor da grade — o núcleo do app

O daemon do Hydra acopla-se ao backplane por um **IOProc** do Core Audio (com ring buffers lock-free entre a thread de áudio e o resto), lê os 256 canais de entrada, **aplica a matriz de patch** e entrega o áudio aos destinos. Esta matriz é a funcionalidade central do produto.

Requisitos que moldam o motor desde o início:

- **Ganho por conexão.** Uma célula da grade não é apenas liga/desliga — cada conexão carrega um valor de **ganho**. O motor **mixa com ganho por conexão** (somando múltiplas fontes num destino com seus respectivos ganhos).
- **Cenas atômicas.** Trocar de cena (Seção 7) aplica uma matriz inteira de uma vez, sem estados intermediários audíveis.
- **Barramento de escuta (monitor).** Um caminho dedicado leva qualquer ponto da grade a uma saída escolhida (ex.: fones) **sem alterar** o patch em produção.

### 5.3 A grade unificada (fontes × destinos)

Tudo no app é uma só grade. As linhas (fontes) e colunas (destinos):

| Fontes (linhas) | Destinos (colunas) |
|---|---|
| Canais de entrada do backplane | Canais de saída do backplane |
| Captura por-app (process tap) | Streams **AES67 TX** (→ rede/Dante) |
| Streams **AES67 RX** (← rede/Dante) | Entradas de cadeias **VST3** |
| Saídas de cadeias **VST3** | — |
| **Entradas de qualquer placa física conectada** (USB, built-in, interfaces, agregados) | **Saídas de qualquer placa física conectada** |

Uma única grade resolve **placas físicas, apps, AES67 e VST3** de uma vez. A UI filtra e agrupa por categoria, mas o modelo de dados é único (Seção 6).

### 5.4 Placas físicas e o problema do clock (drift)

Toda placa conectada ao Mac entra na grade como fonte (entradas) e destino (saídas). O Hydra enumera os devices via Core Audio (`kAudioHardwarePropertyDevices`) e cria um **IOProc próprio** para cada placa usada.

A complicação real é o **clock**: cada placa física roda no próprio relógio, independente do backplane e das demais. Rotear áudio entre devices de clocks diferentes exige **correção de drift** — conversão de sample rate assíncrona (**ASRC**) — senão, com o tempo, acumulam-se cliques/estouros. É exatamente o que um "Aggregate Device" do macOS faz internamente.

Solução de design: cada placa externa ganha um **ring buffer com ASRC** que a alinha ao clock de referência do motor. Custo honesto: ASRC consome um pouco de CPU e adiciona uma latência pequena por device. É um problema conhecido e resolvido, mas é a parte não-trivial deste recurso.

### 5.5 Descoberta de rede

Duas descobertas independentes acontecem na rede, com propósitos diferentes:

- **Presença (quem está online):** escuta passiva de **mDNS/Bonjour** (serviços `_netaudio-*._udp`), um padrão aberto. Fornece a lista de aparelhos presentes na rede, com nome e IP. É leitura de anúncios que os próprios aparelhos transmitem para toda a LAN.
- **Fluxos AES67 (o que dá para receber):** escuta de **SAP** (Session Announcement Protocol) em `239.255.255.255:9875`, que carrega descrições **SDP** dos fluxos disponíveis (endereço multicast, nº de canais, sample rate, codec).

**Cruzamento → selo de status por dispositivo:**

- presente no mDNS **e** anunciando SAP → **"AES67 On"** (assinável);
- presente no mDNS **sem** SAP → **"AES67 Offline"** (existe na rede, mas o modo AES67 não está ligado nele);
- sumiu do mDNS → **offline**.

Limite honesto: o Hydra **vê** um aparelho "AES67 Offline" mas **não liga** o AES67 nele remotamente — isso é uma ação feita no Dante Controller, no próprio aparelho. O status é informativo, com uma dica de habilitação.

### 5.6 Sincronismo — PTP (IEEE 1588v2)

O sincronismo de clock por **PTP** (perfil AES67) é **pré-requisito do envio** de áudio para a rede Dante: sem um relógio comum, o receptor não trava áudio limpo. O Hydra atua como **escravo PTP**, disciplinando seu clock ao grandmaster da rede AES67/Dante.

A recepção tolera mais imperfeição; o envio depende criticamente do PTP. Por isso o roadmap implementa **recepção antes de envio**.

### 5.7 Captura por aplicativo (process taps)

O Hydra captura o áudio de aplicativos específicos usando a API documentada de **Core Audio process tap** (macOS 14.4+). Cada app capturado entra na grade como um **nó**. A captura exige consentimento do usuário (permissão TCC), solicitado no primeiro uso.

### 5.8 VST3

O Hydra hospeda plugins **VST3** e os insere como nós da grade: o sinal de uma fonte passa pela cadeia de plugins antes de chegar ao destino. O host gerencia varredura de plugins (`/Library/Audio/Plug-Ins/VST3`), carga, parâmetros e processamento em bloco.

### 5.9 Estrutura de processos

Dois processos:

- **Daemon** (background, LaunchDaemon): faz todo o trabalho de áudio e rede — IOProcs, matriz, ASRC, AES67, PTP, process taps, VST3.
- **App SwiftUI**: a interface. Não toca em áudio diretamente.

Eles se comunicam por **WebSocket local** (porta dedicada em `127.0.0.1`, ex.: 59731) com mensagens tipadas (JSON). O app é um cliente do daemon; o daemon é a fonte da verdade do estado de áudio.

---

## 6. Modelo de dados (consolidado)

O modelo central, derivado dos requisitos de UX e design:

- **Node (nó):** uma fonte e/ou destino na grade. Tipos (categorias): `backplane`, `physicalDevice`, `app`, `aes67`, `vst`. Cada nó declara as **direções suportadas** (`tx`, `rx`, ou ambas) — um player de mídia é fonte; um app que grava é destino; alguns são ambos. Nós podem ser **detectados automaticamente** (apps, placas, fluxos) ou **adicionados manualmente**.
- **Channel (canal):** pertence a um nó; tem índice, **rótulo editável** pelo usuário (persistido à parte do ID de sistema), e flag **em uso/visível** (para a grade mostrar só o que importa).
- **Connection (conexão):** cruzamento fonte→destino. Carrega um **ganho** (não é booleano). Pode ser selecionada para abrir o Inspector (meter + ganho + escuta).
- **Scene (cena):** snapshot nomeado da matriz inteira — todas as conexões, ganhos e rótulos. Persistida; trocada de forma **atômica**.
- **Identidade persistente:** placas, apps e fluxos têm IDs estáveis para que, ao reconectar após uma queda, o recurso **re-vincule** ao seu patch anterior automaticamente.
- **Event log:** registro leve de eventos (quedas, reconexões, instalações) para avisos discretos.

---

## 7. Fluxo do usuário / UX

### 7.1 Público e prioridades

Público **amplo**: engenheiro de broadcast, produtor/DAW, streamer/podcaster e uso pessoal/lab. Consequência de design: **simples por padrão, profundidade sob demanda**.

As quatro tarefas são todas relevantes, com **AES67/Dante em destaque**: troca de áudio com a rede Dante, roteamento/gravação de apps, patch entre placas físicas e VST3 no caminho.

**Escala típica: 2–16 canais**, apesar do pool de 256. Portanto a grade **nasce pequena e focada**, expandindo só quando preciso.

### 7.2 Primeira execução (first-run)

Um **assistente guiado**: instala o backplane, explica o conceito em poucos passos, solicita as permissões necessárias (captura de áudio por-app) e deixa **um patch inicial pronto** para o usuário ver algo funcionando de imediato.

### 7.3 Acesso e janela

**Janela completa + ícone na menu bar**, compartilhando a mesma fonte de estado. A janela serve para configurar; a menu bar dá status e acesso rápido.

### 7.4 Monitoramento e controle

Por ponto de patch: **meter de nível**, **escuta/monitor (fone)** e **ganho/trim**. (Solo/Mute não são prioridade inicial.) Esses controles aparecem no **Inspector** (Seção 8.1), mantendo a grade limpa.

### 7.5 Navegação da grade

Para conciliar pool de 256 com uso típico pequeno:

- **agrupar por categoria** (Apps, Placas, AES67, VST) com expand/collapse;
- **busca/filtro** por nome;
- **mostrar só canais em uso** por padrão, com opção de expandir.

### 7.6 Apps na grade

Apps abertos aparecem **automaticamente** na grade, no eixo correto conforme a direção que suportam (fonte, destino ou ambos), com opção de **adicionar manualmente**.

### 7.7 Nomeação

Canais, dispositivos e nós têm **rótulos editáveis livremente** (ex.: "Mic Host", "Retorno Palco"), persistidos separadamente do ID de sistema.

### 7.8 Robustez (quedas)

Quando algo desconecta (placa removida, rede cai, app fecha), o Hydra **mantém o patch, religa sozinho quando o recurso volta** e deixa um **aviso discreto** no log de eventos.

### 7.9 Jornada-resumo (happy path)

1. Primeiro uso → o assistente instala o backplane, pede permissões e cria um patch exemplo.
2. Dia a dia → abre pela menu bar ou janela; a grade já vem focada nos canais em uso, agrupada por categoria.
3. Conecta → cruza uma fonte (app/placa/AES67) com um destino; ajusta o ganho no ponto; confere pelo meter; escuta no fone se quiser.
4. Salva como **cena**; troca de cena conforme o contexto ("Live", "Gravação", "Ensaio").
5. Se algo cai, religa sozinho e avisa.

---

## 8. Design / Identidade Visual

- **Estética:** **Pro escuro** (estilo Logic Pro / console). Fundo escuro como padrão, ar de ferramenta profissional. UI em **inglês**, com padrão visual Apple e a experiência do usuário como prioridade.
- **Cor de acento:** **índigo `#5856D6`** (system color da Apple), usada em seleção, conexões ativas e foco.
- **Conexão na grade:** **célula preenchida** (matriz limpa, do tipo cross-point), que escala de 2–16 até 256 sem virar poluição visual.
- **Densidade:** **preferência do usuário** — alternar entre **Adaptive** (espaçoso com poucos canais, compactando conforme cresce) e **Compact** (denso, estilo console).

### 8.1 Conciliação: célula limpa + ganho/meter/escuta

A célula da grade mostra **apenas o estado da conexão**, para a matriz não poluir em escala grande. Ganho, meter e monitor ficam num **Inspector**: ao selecionar uma conexão, abre um painel lateral com **meter do ponto**, **slider de ganho/trim** e botão de **escuta (fone)**. Assim atendemos os requisitos de monitoramento sem encher cada célula de controles.

### 8.2 Resumo visual

| Elemento | Decisão |
|---|---|
| Tema | Pro escuro (padrão), acento índigo `#5856D6` |
| Idioma da UI | Inglês |
| Grade | Matriz de células preenchidas, agrupada por categoria, com busca e "só em uso" |
| Densidade | Toggle Adaptive ↔ Compact |
| Conexão selecionada | Inspector com meter + ganho + escuta |
| Acesso | Janela + menu bar |

---

## 9. Licenciamento e créditos

- **Hydra: GPL-3.0**, desde o primeiro arquivo. Arquivo `LICENSE` (GPL-3.0) e `THIRD_PARTY_NOTICES.md` presentes desde o commit inicial.
- **BlackHole (placa virtual base):** licenciado GPL-3.0. Pode ser embutido e distribuído desde que o Hydra também seja GPL-3.0. **Creditado abertamente** na tela *About* e nas notas de terceiros.
- **VST3 SDK (Steinberg):** dual-license; a opção GPLv3 é compatível com o Hydra GPL-3.0. Incluir os avisos exigidos.
- **NDI SDK (NewTek/Vizrt) — se/quando incluído:** possui **licença própria, não-GPL**. Para não contaminar a distribuição GPL do núcleo, NDI deve ser tratado como **componente opcional**, instalado à parte, seguindo os termos do fornecedor. (NDI não faz parte do núcleo; é uma extensão futura.)

Princípio: **nomear dispositivos como produto é UX; esconder a origem dos componentes não é permitido.** Tudo que é de terceiros é creditado.

---

## 10. Roadmap por fases (cada uma testável no host)

### Fase 1 — Fundação do projeto e backplane
- Esqueleto do projeto (Swift Package Manager), `LICENSE` GPL-3.0, `THIRD_PARTY_NOTICES.md`, `CHANGELOG.md`, versão `0.1.0 beta`.
- Script de build do backplane **256×256** (BlackHole customizado, renomeado) e sua instalação no host.
- Daemon mínimo + app mínimo conectando por WebSocket.
- **Pronto quando:** "Hydra Virtual Soundcard" (256ch) aparece em Audio MIDI Setup e o app conecta ao daemon.

### Fase 2 — Motor da grade (núcleo)
- IOProc acoplado ao backplane; matriz de patch **real** aplicada ao áudio, com **ganho por conexão**.
- Grade na UI: cruzar canal × canal muda o áudio; Inspector com meter + ganho + escuta.
- **Pronto quando:** roteio áudio de um app para outro escolhendo células na grade, com controle de nível.

### Fase 2b — Placas físicas na grade (multi-device + drift)
- Enumerar placas conectadas; IOProc por placa usada; **correção de drift (ASRC)** por device.
- **Pronto quando:** roteio a entrada de uma interface para a saída de outra placa pela grade, sem cliques após vários minutos.

### Fase 3 — Captura por-app (process taps)
- Apps viram nós na grade (TX/RX conforme suportam); permissão TCC no first-run.
- **Pronto quando:** capturo o áudio de um app escolhido e o encaminho pela grade.

### Fase 4 — Recepção AES67 (o "Controller")
- Presença mDNS + descoberta SAP/SDP + selos AES67 On/Offline.
- Assinar fluxos e mapear canais (lado RX).
- **Pronto quando:** recebo áudio de um aparelho Dante (em modo AES67) na grade.

### Fase 5 — PTP real + Envio AES67 (TX)
- PTP escravo ao grandmaster; publicar fluxo SAP/SDP; transmitir RTP alinhado ao clock.
- **Pronto quando:** um aparelho Dante assina o fluxo do Hydra (no Dante Controller) e ouve áudio limpo.

### Fase 6 — VST3 no caminho do sinal
- Cadeias VST3 como nós da grade.
- **Pronto quando:** insiro um plugin entre uma fonte e um destino e ouço o efeito.

### Fase 7 — Cenas, robustez e acabamento
- Cenas (salvar/trocar atômico), reconexão automática + log, rótulos editáveis, toggle de densidade, polimento de UI (English, padrão Apple).
- (Opcional) NDI como extensão à parte; MIDI.
- Empacotar instalador; decidir notarização (Developer ID) se/quando distribuir a terceiros.

---

## 11. Como testar

- Build e execução no próprio MacBook host, com **SIP ligado** (sem reduzir segurança).
- A cada fase, seguir o critério "pronto quando" correspondente, com passos de teste objetivos.
- Para as fases AES67 (4 e 5), é necessário ao menos um aparelho Dante (ou equivalente AES67) na rede, com **AES67 ligado** nele pelo Dante Controller, para validar a interoperação.

## 12. Versionamento e convenções

- Versão semântica `major.minor.patch` + stage (`beta`). Começa em `0.1.0 beta`.
- A cada build, **atualizar a versão e o CHANGELOG**.
- **UI sempre em inglês**, com padrão visual Apple e a experiência do usuário como prioridade.
- Constantes e tipos compartilhados num módulo único (fonte da verdade), importado por daemon e app.
