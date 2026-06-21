# Auditoria de bugs — Hydra Virtual Soundcard

Varredura completa dos três subsistemas (daemon de áudio `hydrad`, rede/IPC, app SwiftUI) em busca de causas de instabilidade. Cada item foi citado no código; os marcados como **✓ verificado** foram conferidos diretamente no arquivo.

---

## Top 5 — mais prováveis de causar a instabilidade que você está vendo

### 1. CRÍTICO — O daemon mata o processo inteiro se o socket de controle falhar ✓ verificado
`Sources/hydrad/WebSocketServer.swift:44-46`

```swift
case .failed(let error):
    log("Listener failed: \(error) — exiting")
    exit(1)
```

O listener WebSocket é só o canal de controle, mas um erro nele (porta em uso ao reiniciar, corrida de reuse, hiccup de permissão/sandbox) chama `exit(1)` e derruba **todo o daemon** — incluindo a engine de áudio ativa. É o candidato número um para "o app fecha sozinho / o áudio some do nada". Deve apenas logar e tentar recriar o listener, nunca encerrar o processo.

### 2. CRÍTICO — Crash na thread de áudio por force-unwrap no render de VST ✓ verificado
`Sources/hydrad/StripManager.swift:168`

```swift
let channelData = source[ch]!
```

`source` aponta para os buffers que o plugin VST3 recebe. O SDK permite que o `process()` do plugin substitua esses ponteiros — um plugin mal comportado pode deixar um `nil`. O `!` então faz trap e mata o daemon **a partir da thread de tempo real**. Trocar por `guard let channelData = source[ch] else { continue }`.

### 3. CRÍTICO/ALTO — Retain cycle vaza cada "app tap" capturado ✓ verificado
`Sources/hydrad/ProcessTapManager.swift:125`

```swift
... AudioDeviceCreateIOProcIDWithBlock(&pid, aggregateID, nil) { [self] _, inputData, _, _, _ in
```

O bloco do IOProc captura `[self]` forte. Esse bloco vive dentro do `procID`, que o próprio `AppTap` possui → ciclo `self → procID → bloco → self`. O `deinit` (que chama `stop()` e libera buffers/aggregate device) **nunca roda** a menos que `stop()` seja chamado explicitamente antes de soltar a referência. Em uma sessão com abas de navegador / helpers nascendo e morrendo (o código reconstrói taps para isso), aggregate devices e process taps do CoreAudio vão acumulando até desestabilizar o subsistema de áudio. Os outros IOProcs (`DeviceIO`, `AudioEngine`) capturam só locais — corrigir para o mesmo padrão (`[weak self]` ou capturar `ring`/`scratch`/`channels` locais, como já é feito parcialmente).

### 4. CRÍTICO — Corridas na reconexão do app deixam a UI em estado errado ✓ verificado
`Sources/HydraApp/DaemonClient.swift:350-376, 440-455`

`connect()` sobrescreve `self.task` sem cancelar o anterior, e um erro de `send()` agenda `handleDisconnect()` de forma assíncrona. Se um `send` falhar durante uma tentativa de reconexão, o `handleDisconnect` atrasado cancela a task **nova** e zera `task`, deixando o cliente permanentemente desconectado mesmo com o daemon no ar. Também é possível terminar com duas `URLSessionWebSocketTask` vivas e dois loops de recepção, fazendo `connectionState` oscilar. Esse é o mecanismo direto do sintoma "o app perde sincronia com o daemon". Precisa cancelar a task antiga em `connect()` e guardar contra reentrância.

### 5. ALTO — Erros de envio do daemon são engolidos; clientes mortos nunca são removidos ✓ verificado
`Sources/hydrad/WebSocketServer.swift:111-128`

```swift
connection.send(..., completion: .contentProcessed { _ in })
```

O erro de envio é descartado e `broadcast` itera conexões que podem estar em teardown. Um cliente meio-aberto continua "recebendo" broadcasts que silenciosamente falham; o daemon nunca percebe nem faz prune. É a principal causa de **dessincronia app↔daemon**: o daemon assume entrega e não dispara resync. Verificar o erro de completion e remover a conexão em falha.

---

## Outros achados relevantes

### Daemon de áudio (`hydrad`)

- **MÉDIO — Liberar snapshot na thread de controle pode travar em `main.sync`.** `MatrixStore.swift:448-449` + `StripManager.swift:120`: ao descartar snapshots antigos, o `deinit` de `ChainTap` faz `DispatchQueue.main.sync`; se a main estiver ocupada, a fila de controle trava.
- **MÉDIO — `makeupGain`, `meters[]`, `inputPeaks/outputPeaks` lidos na thread de áudio e escritos no controle sem sincronização.** `ProcessTapManager.swift:132/181`, `MatrixStore.swift:622/363/368`. Float não tearam em arm64/x86_64, então é "benigno", mas é data race real — documentar/atomizar.
- **MÉDIO — `ptpTimeNow()` usa `NSLock`.** `PtpClock.swift:74` — hoje só é chamado de threads de sender (AES67 TX), ok; vira risco de inversão de prioridade se algum dia for chamado da thread de render.
- **BAIXO — `OSStatus` de `AudioObjectAddPropertyListenerBlock` ignorado** em `AudioEngine.swift:95`, `ProcessTapManager.swift:208`, `DeviceManager.swift:173`: se o registro falhar, hot-plug/contagem de XRUN silenciosamente nunca dispara.
- **Corretos (sem alarme falso):** `ChannelRing` (SPSC sem lock/alloc), `MatrixStore.process` (alloc-free, `os_unfair_lock_trylock`), e o ring GUI→áudio do VST estão bem feitos.

### Rede / IPC

- **ALTO — Estouro de leitura no parser RTP/AES67.** `Aes67Manager.swift:198-217`: o caminho de 24-bit lê `bytes[b+2]`; índice vindo dos canais do SDP, não do pacote real. Pacote multicast malformado/malicioso pode indexar fora do `Data` → crash em thread de rede. Revalidar limites por índice.
- **ALTO — Recursão sem limite de profundidade em bundles OSC.** `Osc.swift` `parseBundle`: um `#bundle` aninhado recursivamente sem limite causa stack overflow com datagrama forjado. Adicionar limite de profundidade.
- **ALTO — `OscServer` para o loop de recepção no primeiro erro, sem recuperar nem cancelar a conexão.** `OscServer.swift:64-66`: mensagens OSC daquele peer ficam perdidas para sempre e a `NWConnection` vaza.
- **MÉDIO — Reconexão do app com delay fixo de 2s, sem backoff,** e `connect()` envia `getStatus` antes do socket estar `.ready`. `DaemonClient.swift:350-356, 467-475`.
- **MÉDIO/BAIXO — Threads de TX (NDI/AES67) são destacadas e não dão join; `deinit` desaloca buffers (`Aes67Tx.swift:111`, `NdiManager.swift:66/144`).** Mitigado por `[weak self]` no loop, mas ainda é uma corrida de teardown a vigiar.
- **Correto:** parsing de SAP/SDP em `HydraCore/Aes67.swift` é sólido (bounds-check em cada offset, sem force-unwrap).

### App SwiftUI (`HydraApp`)

- **ALTO — `MenuBarPanel.openMainWindow()` usa `openWindow(id:"main")` sem `@Environment(\.openWindow)` no escopo.** ✓ verificado: a variável só é declarada dentro de `AboutCommands`, não em `MenuBarPanel` (`MenuBarPanel.swift:188` vs `202`). Se compilar, há uma extensão escondida; se não, o "Abrir Hydra" do menu bar está quebrado — num app menu-bar-first isso deixa sem forma de abrir a janela. **Verificar contra um build real.**
- **ALTO — Script shell privilegiado montado por interpolação de strings.** `InstallManager.swift:189-219`: caminhos vindos de `Bundle.main.bundleURL` entram no `/bin/sh` sem escape robusto; um `"` no caminho do app quebra o script rodando como root. Usar argumentos quotados/escapados de verdade.
- **ALTO — `ContentView.onAppear` pode disparar prompt de admin + `killall coreaudiod`.** `ContentView.swift:105-114` + `InstallManager.swift:128-139`: `onAppear` num app menu-bar dispara várias vezes; se as versões do driver diferirem, reinicia o coreaudiod no meio da sessão (derruba o áudio). Mover para um ponto idempotente de ciclo de vida.
- **MÉDIO — `SyncedValue` pode engolir valores do servidor indefinidamente** se o daemon clampar um valor diferente do enviado (`SyncedValue.swift:68-79`): sliders de ganho/makeup ficam mostrando valor que o daemon rejeitou.
- **MÉDIO — `DeviceViewPatch.sourcesConnected` usa `Dictionary(uniqueKeysWithValues:)` que faz trap em chave duplicada.** `DeviceViewPatch.swift:346-360`: dois sources com mesmo `id` (após glitch de reconexão) → crash. Usar inicializador com `uniquingKeysWith:`.
- **MÉDIO — Custo quadrático na main thread.** `GridView.swift:680-705` (`signalMarks`/`connIDs` refazem `connections.filter` por canal a cada render) e `DeviceViewPatch.swift:346` (dicionário reconstruído por linha). Em setups grandes vira travamento de UI. O `connectionIndex` do `DaemonClient` não é aproveitado aqui.
- **MÉDIO — Fallback de dev em `DaemonService.enable()` pode subir dois `hydrad`.** `DaemonService.swift:74-117`: após `register()`, sleep fixo de 1.5s + checagem de processo (TOCTOU); se o launchd for lento, dois daemons disputam a mesma porta.
- **BAIXO — `remove(at:index)` com `ForEach(...indices, id:\.self)`** em `StripGridView.swift:242` e `InspectorView.swift:156/298`: padrão clássico de out-of-bounds se um echo do daemon reduzir o array entre o tap e o render.

---

## Sugestão de ordem de correção

1. `exit(1)` no listener (#1) e force-unwrap no VST (#2) — eliminam crashes diretos.
2. Retain cycle do AppTap (#3) — para o vazamento progressivo que degrada o áudio ao longo da sessão.
3. Corridas de reconexão (#4) + erros de send engolidos (#5) — resolvem a dessincronia app↔daemon.
4. Parsers de rede (RTP/OSC) — robustez contra entrada de rede malformada.
5. Resto por severidade.

> Observação: esta é uma análise estática. Recomendo validar #1–#5 reproduzindo com Address Sanitizer / Thread Sanitizer ligados e o Instruments (Leaks/Allocations) numa sessão longa com apps entrando e saindo.

---

## Correções aplicadas (nesta sessão)

| # | Arquivo | O que mudou |
|---|---------|-------------|
| 1 | `WebSocketServer.swift:44` | `.failed` do listener agora **loga e mantém o daemon vivo** em vez de `exit(1)`. |
| 2 | `StripManager.swift:166` | Removido o `source[ch]!` no render de VST; usa `guard let … else { silêncio; continue }`. |
| 3 | `ProcessTapManager.swift` | Novo `FloatBox`; `makeupGain` virou propriedade computada apoiada no box; o IOProc **não captura mais `self`** → `deinit` roda e o tap não vaza. |
| 4 | `DaemonClient.swift` | `connect()` cancela a task anterior; `handleDisconnect(_:)` ignora callbacks de tasks já substituídas; `send` casa o erro à task correta; reconexão com **backoff exponencial** (até 30s). |
| 5 | `WebSocketServer.swift:111` | Erro de `send` agora **remove a conexão morta** (cancela + prune) em vez de ser engolido. |
| 6 | `Osc.swift:62` | `parseBundle` ganhou **limite de profundidade** (8) contra stack overflow por bundles aninhados. |
| 7 | `OscServer.swift:64` | Em erro de recepção a `NWConnection` é **cancelada** (não vaza mais). |
| 8 | `Aes67Manager.swift:198` | Guard contra **divisão por zero** quando `frameBytes == 0` (stream com 0 canais). |
| 9 | `DeviceViewPatch.swift:347` | `Dictionary(uniquingKeysWith:)` no lugar de `uniqueKeysWithValues` → não trava com IDs duplicados. |
| 10 | `MenuBarPanel.swift:17` | Adicionado `@Environment(\.openWindow)` que faltava (corrige "Abrir Hydra"). |
| 11 | `StripGridView.swift` / `InspectorView.swift` (3 sites) | `remove(at:)` protegido por `indices.contains(index)` (out-of-bounds em `ForEach` por índice). |
| 12 | `InstallManager.swift:192` | Caminhos do script privilegiado agora **single-quoted** (`shellQuote`) → sem quebra/injeção em path com espaços/aspas. |
| 13 | `InstallManager.swift` | Adicionada flag estática `didCheckDriverRefresh` para tornar a verificação e prompt de atualização de driver idempotentes por execução (resolvendo o problema de `ContentView.onAppear` disparar prompts adicionais). |
| 14 | `PatchMatrixTests.swift` | Extraídas chamadas de método mutante `m.upsert` e `m.remove` de dentro de macros `#expect` para compilar sob Swift 6.3 / Xcode 26.5. |

**Compilação Validada** (projeto buildado com sucesso no Xcode 26.5 e macOS 26.5.1; todos os 51 testes unitários passaram com sucesso).

### Itens do relatório ainda NÃO corrigidos (decisão sua)
- Liberação de snapshot na thread de controle podendo bloquear em `main.sync` (`MatrixStore`/`StripManager`) — precisa de mais cuidado de design.
- Custo quadrático na main thread no `GridView`/`DeviceViewPatch` (performance, não crash).
- Data races "benignas" de metering (Float não-sincronizado) — só documentação/atomização.
- Threads de TX (NDI/AES67) não dão `join` no teardown — mitigado por `[weak self]`, baixa prioridade.
