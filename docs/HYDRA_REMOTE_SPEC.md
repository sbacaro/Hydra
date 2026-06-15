# Hydra Remote — Especificação (Camada 2)

Monitoramento remoto pela internet, estilo Listento, embutido no Hydra.
**Status: definido, não iniciado.** Entra no roadmap após: teste de campo da
0.15.x, bug do EQ nos inserts, e Fase 5 (PTP + validação AES67 com hardware).

## 1. Objetivo

Uma interface virtual ganha o flag **Remote TX**: o que for roteado aos seus
canais Out é transmitido pela internet (P2P, baixa latência, Opus). Qualquer
pessoa com o **SonoBus** (grátis, macOS/Windows/Linux/iOS/Android) entra no
grupo e ouve — o ecossistema receptor já existe, não construímos app de
ouvinte nem servidor próprio no v1.

### Não-objetivos do v1
- Receptor no navegador (link de convite web) — é a Camada 3, exige gateway
  WebRTC e infraestrutura própria.
- RX (receber áudio remoto como fonte na grade) — v2 desta feature; o modelo
  já comporta (AOO sink → EngineTap, mesmo padrão do Aes67Rx/NdiRx).
- Talkback/chat.

## 2. Por que AOO (e não o SonoBus inteiro)

O SonoBus é um app JUCE; o motor de rede dele é a biblioteca **AOO**
("Audio over OSC", de Christof Ressi) — C/C++ com **API C pura** (interop
Swift fácil, mesmo padrão dos nossos shims), GPLv3 (compatível com o Hydra),
com Opus, jitter buffer, resampling e recuperação de pacotes embutidos.
Falando AOO + a semântica de grupos do SonoBus, o SonoBus vira nosso receptor.

Licenças: AOO GPLv3 ✓ · Opus BSD ✓ · JUCE **não é necessário** ✓.
Atualizar THIRD_PARTY_NOTICES.md e o About quando implementar.

## 3. Arquitetura (espelha o padrão NDI/VST do projeto)

- **Target C/C++ `HydraAOO`**: vendoriza AOO + Opus em `ThirdParty/`
  (gitignorado), baixados por `Scripts/fetch_aoo.sh` (como o VST3 SDK).
  Fachada C mínima exposta ao Swift: `haoo_connect(server, group, password)`,
  `haoo_source_create(name, channels, rate, bitrate)`,
  `haoo_source_send(interleaved, frames)`, `haoo_listeners_count()`,
  `haoo_disconnect()`.
- **`RemoteManager`** (daemon): mesmo formato do NdiManager — `syncTx(interfaces:)`
  cria um sender AOO por interface com `remoteTX`, alimentado por um
  **PoolTxTap** (fatia Out pós-mix, infraestrutura já existente). Thread de
  envio em chunks de 10 ms; eventos no EventCenter (conectado, ouvinte
  entrou/saiu, queda/reconexão com backoff).
- **Conexão**: connect server para atravessar NAT — default o público do
  SonoBus (`aoo.sonobus.net`), com campo para self-host (`aooserver`, também
  GPL). Depois da apresentação, o áudio flui P2P/UDP.

## 4. Modelo e protocolo WS

- `VirtualInterfaceInfo.remoteTX: Bool` (decode tolerante, como ndiTX/aes67TX).
- `ConfigPayload`: `remoteServer: String`, `remoteGroup: String`,
  `remoteBitrateKbps: Int` (96/128/256 por par, default 256). Senha do grupo
  NÃO persiste em texto plano — Keychain no daemon.
- Mensagens: `setInterfaceRemote(InterfaceNDIPayload)` (reutiliza o payload),
  `remote(RemotePayload)` com `{connected, group, listeners: [String], flows}`.

## 5. UX

- **Criação**: template novo "Remote" (ícone `dot.radiowaves.up.forward`,
  0 in × 2 out, remoteTX ligado).
- **Linha da interface** (sidebar): terceiro badge ao lado de AES67/NDI.
- **Settings → Control**: seção Remote (servidor, grupo, senha, bitrate).
- **Network → "Hydra on the network"**: flow Remote com status (conectado,
  N ouvintes, bitrate) — os nomes dos ouvintes são a "presença" do Listento.

## 6. Critérios de aceitação

1. SonoBus em outra máquina (fora da LAN) entra no grupo e ouve a interface
   com latência < 500 ms e sem dropouts audíveis por 10 min.
2. Queda de rede → reconexão automática + toast; ouvinte entra/sai → evento.
3. Desligar o flag remove o flow imediatamente (bye limpo).
4. CPU do daemon estável (< +10% vs. baseline) com 1 flow estéreo.

## 7. Riscos conhecidos

- Compatibilidade de protocolo com o SonoBus depende da versão do AOO — fixar
  tag e validar contra o SonoBus release atual no primeiro teste.
- Connect server público é cortesia do projeto SonoBus — para uso sério,
  documentar o self-host do `aooserver`.
- Teste real exige duas redes distintas (VM não basta); planejar com uma
  segunda máquina/celular 4G.
