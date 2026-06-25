# Projeto: Múltiplos Hydra Audio Bridges (canais fixos)

Status: **plano / em implementação**. Substitui o modelo de "uma soundcard de 256
canais + interfaces virtuais fatiáveis" por um **catálogo fixo de 8 dispositivos
CoreAudio**, cada um com entrada e saída.

## Decisões (confirmadas com o usuário)

1. **8 dispositivos CoreAudio separados** — cada bridge aparece no Audio MIDI
   Setup e é selecionável por qualquer app.
2. **Toggle por bridge** — catálogo fixo; o usuário liga/desliga cada um.
3. **Remover as interfaces virtuais customizadas** — sai `Add Interface`, o
   `InterfaceStore` e o fluxo de fatiar o pool.
4. **N in + N out por bridge** — cada bridge é um loopback independente (estilo
   BlackHole).

## O set fixo

| id      | Nome no macOS              | Canais (in = out) |
|---------|----------------------------|-------------------|
| `2a`    | Hydra Audio Bridge 2-A     | 2                 |
| `2b`    | Hydra Audio Bridge 2-B     | 2                 |
| `4`     | Hydra Audio Bridge 4       | 4                 |
| `8`     | Hydra Audio Bridge 8       | 8                 |
| `16`    | Hydra Audio Bridge 16      | 16                |
| `32`    | Hydra Audio Bridge 32      | 32                |
| `64`    | Hydra Audio Bridge 64      | 64                |
| `128`   | Hydra Audio Bridge 128     | 128               |

(2+2+4+8+16+32+64+128 = 256, mas como agora são dispositivos independentes, cada
um tem seu próprio loopback — não há mais um pool compartilhado de 256 wires.)

## Arquitetura atual (de onde partimos)

- **Driver** (`Backplane/Driver/Hydra.c`): BlackHole customizado, **um** device
  ("Hydra Virtual Soundcard"), 256 canais, loopback `out N → in N` via ring
  compartilhado. Toda a inteligência de patch está no engine.
- **Engine** (`Sources/hydrad`): **um** IOProc no backplane; `MatrixStore.process`
  lê os inputs (loopback do que apps escreveram) e escreve os outputs aplicando a
  matriz. Dispositivos físicos têm um caminho à parte com rings + ASRC (clocks
  independentes) em `DeviceManager`.
- **Modelo** (`Sources/HydraCore`): `Hydra.backplaneNodeID` único; `poolChannels`;
  `VirtualInterfaceInfo` = fatia `[inBase, inBase+inChannels)` / `[outBase, …)`.
- **UI**: as interfaces todas colapsam no nó `backplane` (faixas de canal). Sidebar
  cria/edita interfaces.

## Arquitetura nova (para onde vamos)

Cada **bridge** é um nó próprio do grid (`bridge:<id>`), mapeado para seu device
CoreAudio por UID. O engine anexa um caminho de I/O por bridge habilitado, e a
matriz roteia livremente **entre bridges, dispositivos físicos, rede e plugins**.

### Driver (Fase 2) — o ponto mais arriscado

Duas abordagens (não dá para compilar/testar HAL fora do Mac; precisa iteração):

- **A (recomendada): 1 plugin, N devices.** Generalizar o modelo de objetos do
  BlackHole (hoje 1–2 devices hardcoded) para um array de descritores
  `{nome, uid, canais}` × 8, mais **8 boxes** (um por device) para o toggle. Um
  bundle só, instalação limpa. Risco: refator C considerável dos object-IDs.
- **B (fallback): 8 bundles parametrizados.** Cada bundle é o driver single-device
  atual (que já funciona), só mudando as macros do topo (`kNumber_Of_Channels`,
  `kDevice_Name`, `kDriver_Name`/UID, bundle id) via script gerador. Risco C baixo
  (reusa código provado), porém 8 plugins em `/Library/Audio/Plug-Ins/HAL`.

**Toggle (ligar/desligar):** usar `kAudioBoxPropertyAcquired`. Cada device fica
atrás de um box; box não-adquirido ⇒ device oculto no macOS. O engine adquire o
box dos bridges habilitados via API CoreAudio padrão (`AudioObjectSetPropertyData`)
— sem IPC custom. O BlackHole já tem o mecanismo de box-acquire; só precisa iniciar
não-adquirido e ser por-device.

### Engine (Fase 3)

- Um **BridgeManager** liga/desliga cada bridge (adquire/solta o box) e mantém o
  estado persistido (quais estão ativos).
- Cada bridge ativo é anexado **reusando o caminho de dispositivos do
  `DeviceManager`** (IOProc + ring + ASRC), já que são devices CoreAudio com clock
  próprio. Bridges são reconhecidos pelo prefixo de UID e expostos como nós
  `bridge:<id>` (não como `dev:<uid>` genérico), para receberem UI/branding
  próprios e não aparecerem na lista de "dispositivos físicos".
- `MatrixStore.process` deixa de assumir um backplane único; passa a operar sobre
  os buffers de cada nó de bridge. O roteamento entre bridges atravessa os rings
  com ASRC (mesma mecânica já usada para físicos).
- `AudioEngine` (IOProc único do backplane) e `BackplaneProbe` saem/viram
  utilitários multi-device.

### Modelo (Fase 1)

- `Hydra.bridgeCatalog`: os 8 descritores fixos (`id`, `name`, `channels`).
- `Hydra.bridgeNodeID(id:)` / `bridgeID(fromNodeID:)`, e o UID CoreAudio por
  bridge.
- `BridgeInfo` (substitui `VirtualInterfaceInfo`): `id`, `name`, `channels`,
  `enabled`, `present` (device visível no sistema?).
- Mensagens WS: `bridges` (estado), `setBridgeEnabled(id, enabled)`. Remover
  `createInterface`/`deleteInterface`/`setInterface*`.
- Remover `poolChannels`/`backplaneNodeID`/`InterfaceStore` (ou marcar legado e
  migrar).

### UI/UX (Fase 4)

- Sidebar: seção **Bridges** listando os 8 do catálogo, cada um com toggle on/off e
  contagem de canais; ativos viram nós no grid.
- Remover `AddInterfaceForm` e o fluxo de criação.
- Grid/Inspector/MenuBar/Welcome/Settings adaptados (cada bridge = um nó).
- NDI/AES67 TX hoje ligados a interfaces ⇒ religar a bridges (ou a um nó-bridge).

### Packaging / migração (Fase 5)

- Build do driver (multi-device ou multi-bundle) + instalador `.pkg`.
- Migração de dados: patches/scenes que apontavam para `backplane`+faixas das
  interfaces antigas precisam ser remapeados ou descartados com aviso.
- Atualizar `README`/`docs/ARCHITECTURE`.

## Ordem de implementação e riscos

1. **Fase 1 (modelo)** — segura, destrava o resto. *Começa já.*
2. **Fase 2 (driver)** — fundação; **risco alto**, exige Mac. Sem os devices, nada
   roda.
3. **Fase 3 (engine)** — reusa o caminho de devices físicos; risco médio.
4. **Fase 4 (UI)** — grande, mas mecânica.
5. **Fase 5 (packaging/migração/docs)** — fecha.

**Não testável neste ambiente:** o driver HAL e o áudio em tempo real exigem
macOS + CoreAudio + hardware. Cada fase será entregue para build/iteração no Xcode.
