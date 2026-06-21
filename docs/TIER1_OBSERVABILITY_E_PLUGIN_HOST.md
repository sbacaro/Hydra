# Tier 1 — Observabilidade + Host de plugin fora-de-processo

Duas frentes entregues juntas. **Não compilei aqui** (macOS + CoreAudio + SDK
VST3; o ambiente é Linux sem toolchain Swift) — validei por revisão. A
observabilidade deve compilar limpa; o host XPC é um **incremento 1** que pode
exigir ajustes no primeiro build real no seu Xcode.

---

## 1. Observabilidade (pronta para usar)

**`Sources/HydraCore/HydraLog.swift`** — facility única de `os.Logger` para todo
o produto (subsystem `audio.hydra`), com categorias (`daemon`, `audio`,
`network`, `plugin`, `device`, `install`, `app`) e um `OSSignposter` para o
áudio.

Mudanças:
- O `log()` do daemon agora roteia para o unified logging (persistente, sobrevive
  a relaunch) **e** ecoa no stdout. Ver depois com:
  ```
  log show --predicate 'subsystem == "audio.hydra"' --info --last 1h
  ```
- O ciclo de render (`AudioEngine`) é instrumentado com `os_signpost`
  (intervalo `render` + evento `xrun`). Abra o **Instruments → Points of
  Interest** e filtre pelo subsystem `audio.hydra` para caçar dropouts em vez de
  adivinhar. Custo zero quando nada está gravando.

**`Sources/HydraApp/Diagnostics.swift`** + botão em **Settings → Advanced →
Diagnostics → "Export Diagnostics…"**: coleta as últimas 2h de log do app **e**
do daemon (via `log show`), ambiente e status, num único `.txt` para anexar em
tickets de suporte.

---

## 2. Host de plugin fora-de-processo (incremento 1 — isolamento de crash)

**Objetivo:** um VST3 que crasha mata só o processo host, **não** o daemon. Hoje
um plugin ruim derruba o hydrad inteiro (foi o crash que corrigimos antes).

### Arquitetura
- **`Sources/HydraPluginHostABI/`** — transporte por memória compartilhada (C):
  header de controle + buffers de áudio em 4 slots (SPSC, sem tearing) +
  handshake lock-free por contadores de sequência com acquire/release. Wrappers
  C não-variádicos (`hydra_shm_create`/`hydra_shm_open_rw`) para o Swift chamar.
- **`Sources/hydra-plugin-host/`** — executável separado que mapeia o shm, carrega
  a cadeia VST (reusando o shim `HydraVST`), faz busy-poll do `inputSeq`,
  processa e publica o resultado + heartbeat.
- **`Sources/hydrad/RemotePluginHost.swift`** — lado daemon: cria o shm, lança e
  **monitora** o filho (relaunch com backoff em crash; watchdog de heartbeat
  para travamento). `process(input:output:frames:)` é **RT-safe**: só memcpy +
  atômicos, **nunca bloqueia**; passa o sinal **seco** enquanto o host prima,
  atrasa ou morre.
- **Integração opt-in** em `ChainTap` (StripManager): quando a cadeia roda
  remota, o `render` delega ao `RemotePluginHost`. Custo: ~1 bloco de latência
  nas tiras com insert.

### Como testar (caminho mais fácil: SwiftPM)
```bash
swift build                                   # compila hydrad + hydra-plugin-host lado a lado
HYDRA_REMOTE_PLUGINS=1 .build/debug/hydrad     # liga o modo fora-de-processo
```
Com o flag ligado, carregue um insert num strip e toque áudio. Para ver o
isolamento: mate o `hydra-plugin-host` (`pkill hydra-plugin-host`) — o áudio
passa seco e o daemon relança o host sozinho (veja os logs `PluginHost:`).
**Sem o flag, o comportamento é idêntico ao de hoje** (in-process), então é
seguro de mesclar.

### Limitações conhecidas (próximos incrementos)
- **Sem sync de parâmetros e sem GUI** ainda: o editor do plugin continua
  in-process no caminho antigo; no modo remoto os parâmetros do plugin não são
  controláveis pela UI. O próximo passo é mover o hosting da janela do editor
  para o processo host (onde a instância já vive) e abrir um ring de parâmetros
  GUI→host no shm.
- **+1 bloco de latência** nas tiras hospedadas remotamente (configurável depois;
  dá pra fazer lock-step de baixa latência com um relay thread não-RT).
- **Build do Xcode/empacotamento**: adicionei o target `hydra-plugin-host` e o
  framework `HydraPluginHostABI` ao `Package.swift` e ao
  `generate_xcodeproj.rb` (embarcado em `…/Helpers/`), mas como não consigo rodar
  o gerador aqui, o rpath/assinatura/empacotamento são os pontos mais prováveis
  de precisarem de um ajuste no primeiro build. O caminho SwiftPM acima evita
  isso para testar a lógica.
- Se o host ficar 4+ blocos atrasado (sobrecarga), pode haver tearing — aceitável
  num protótipo; nesse ponto o áudio já estaria quebrando de qualquer forma.

### Arquivos novos
```
Sources/HydraCore/HydraLog.swift
Sources/HydraApp/Diagnostics.swift
Sources/HydraPluginHostABI/include/hydra_plugin_shm.h
Sources/HydraPluginHostABI/hydra_plugin_shm.c
Sources/HydraPluginHostABI/module.modulemap
Sources/hydra-plugin-host/main.swift
Sources/hydrad/RemotePluginHost.swift
```
### Arquivos tocados
`Package.swift`, `Scripts/generate_xcodeproj.rb`, `Sources/hydrad/AudioEngine.swift`,
`Sources/hydrad/WebSocketServer.swift`, `Sources/hydrad/StripManager.swift`,
`Sources/HydraApp/SettingsView.swift`.
