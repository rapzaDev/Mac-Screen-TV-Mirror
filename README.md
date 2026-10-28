# MacMirror

Aplicativo nativo para transmitir a tela inteira do Mac pela LAN, sem assinatura ou limite artificial. SwiftUI + ScreenCaptureKit/AVFoundation + H.264 VideoToolbox + FFmpeg para AAC/multiplexação (vídeo codificado nativamente). Não usa nuvem, telemetria, AirPlay ou Miracast.

**FUNCIONAL NA SAMSUNG UN32T4300AGXZD: imagem real e áudio confirmados pelo usuário.** O usuário informou que o som estava saindo na TV e no Mac. Esta revisão adiciona ícone nativo e usa o modo Core Audio `mutedWhenTapped` para reproduzir o som capturado somente na TV enquanto a captura estiver ativa. O usuário confirmou fisicamente: som somente na TV durante o espelhamento e retorno ao Mac após Parar. Veja [docs/VALIDACAO.md](docs/VALIDACAO.md).

## Executar neste Mac

```sh
./scripts/run.sh
```

Aplicativo compilado: **`/Users/ti/Documents/espelhamento_tela/dist/MacMirror.app`**. Também pode abrir esse arquivo pelo Finder. O pacote é assinado ad hoc, para uso local; não foi notarizado nem preparado para distribuição pública.

1. Mantenha o Mac e a TV ligados na mesma rede local, sem isolamento entre clientes Wi-Fi.
2. Clique em **Buscar**, aguarde a descoberta terminar e confirme a Samsung selecionada; ou informe o IPv4 da TV em **Testar IP**. A TV identificada nesta rede é **Samsung UN32T4300AGXZD**, `192.168.0.13`; o endereço pode mudar por DHCP.
3. Selecione o monitor e o preset **Equilibrado** (1280×720, 30 FPS, alvo de 3 Mbps). O bitrate medido varia com o conteúdo; tela parada usa menos banda.
4. Mantenha **Iniciar reprodução na TV por DLNA** habilitado para tentar a abertura automática. O teste HLS por DLNA é uma alternativa para outros aparelhos; esta Samsung respondeu `Illegal MIME-type` para HLS nesse caminho.
5. Em **Som e atraso**, mantenha **Transmitir áudio do sistema para a TV** e **Menor atraso** selecionados. Clique em **Iniciar espelhamento**. Autorize MacMirror para gravação de tela e áudio do sistema pelo aviso oficial. Se solicitado, autorize rede local e conexões de entrada somente para este aplicativo.
6. Se a TV não abrir a imagem, acesse no navegador dela **`http://IP_DO_MAC:8787/tv`** e informe o código de 16 caracteres mostrado no MacMirror. O botão **Copiar endereço completo** inclui o código no endereço. `IP_DO_MAC` nesta inspeção: `192.168.0.12`.
7. A página verifica HLS nativo e tenta reproduzir vídeo real. Se o navegador não oferecer HLS, consulte [o receptor Tizen AVPlay](docs/TIZEN.md). Uma página aberta sem vídeo não é validação.
8. Reproduza um vídeo no Mac. Durante a captura de áudio, o som dos aplicativos capturados sai somente na TV; ao parar, o Core Audio libera a reprodução local automaticamente. O volume e a saída padrão do Mac não são alterados. O indicador **Áudio capturado** mostra o nível efetivamente recebido; silêncio aparece como **aguardando som dos aplicativos**. Ajuste o volume da TV. O botão **Testar neste Mac** abre uma prévia sem som para evitar recaptura/eco. Use **Comparar atraso com um relógio** para comparar visualmente Mac e TV.
9. Use **Parar espelhamento** para fechar os espectadores, parar captura/encoder/FFmpeg, revogar o código e remover os segmentos.

Após recompilar com assinatura ad hoc, o macOS pode manter uma autorização referente à assinatura anterior, mesmo exibindo o botão habilitado. Se remover/adicionar pelo painel não resolver, feche o MacMirror e redefina **apenas a permissão desse app**, pelo mecanismo oficial:

```sh
tccutil reset ScreenCapture local.macmirror.app
open "$PWD/dist/MacMirror.app"
```

Isso não concede acesso: será necessário autorizá-lo novamente nos Ajustes do Sistema. Não execute reset global de permissões. O script de build mantém a cópia `dist` como destino de abertura, evitando confusão com a cópia intermediária do Xcode. A Apple [confirma o vínculo da autorização à identidade de assinatura](https://developer.apple.com/forums/thread/819406); um certificado Apple Development estável evita reautorizações entre builds, mas não é exigido para executar este build local ad hoc.

Se a permissão for negada: **Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema → MacMirror**. Reabra o aplicativo se o macOS solicitar. Não é necessário desabilitar firewall, SIP ou outras proteções.

## Requisitos e dependência gerenciada

- macOS 14 ou posterior (áudio do sistema exige 14.2 ou posterior), Xcode/Command Line Tools para recompilar. Build fornecido: universal (`arm64` e `x86_64`), executado e validado em Apple Silicon neste macOS 26.3.1/Xcode 26.2. A arquitetura Intel foi compilada, mas não executada nesta sessão.
- FFmpeg com muxers `hls`, `mpegts`, `tee`, `nut`, encoder AAC e filtros `setts`/`h264_metadata`. Neste Mac já existe **`/opt/homebrew/bin/ffmpeg`**, versão 9.0.2. O aplicativo verifica o executável em seus Resources, em `MACMIRROR_FFMPEG`, `/opt/homebrew/bin/ffmpeg` ou `/usr/local/bin/ffmpeg` e mostra erro se ausente.
- O FFmpeg **não está embutido** no `.app`: este pacote depende da instalação existente e das bibliotecas dela. Nenhum software de sistema foi instalado durante o desenvolvimento. Em outro Mac, instale uma compilação confiável por sua conta ou configure o caminho antes de executar o binário. Consulte a [licença e requisitos de redistribuição do FFmpeg](https://ffmpeg.org/legal.html) antes de empacotá-lo. O build Homebrew local informa GPL; o projeto não redistribui esse binário.
- Não exige Apple Developer Program pago para uso local. Certificados Tizen são uma exigência distinta, apenas se instalar o receptor opcional.

## Compilar e testar

```sh
./scripts/build.sh       # Xcode, assinatura ad hoc, cópia em dist/
./scripts/test.sh        # XCTest/integração com frames sintéticos e testes JS
swift run MacMirrorProbe --discover
```

Prova de transmissão sem permissão de tela (barras animadas, explicitamente sintéticas):

```sh
swift run MacMirrorProbe --seconds 90 --audio-tone --responsive
# Copie a URL HLS impressa para um cliente HLS.
# Em outro terminal, mantendo o produtor ativo:
.build/debug/MacMirrorProbe --play-url 'URL_HLS_IMPRESSA' --seconds 20
ffmpeg -i 'URL_HLS_IMPRESSA' -t 20 -f null -
```

`--tv IP` tenta a reprodução DLNA. `--screen` no Probe usa captura real e tem sua própria identidade/permissão de executável; prefira testar a tela pelo aplicativo gráfico. `--audio-tone` gera apenas um tom sintético; `--system-audio` solicita captura real do som pela identidade do executável. Não combine captura real com `--export`; o Probe bloqueia essa exportação. O Probe só transmite quando executado explicitamente e termina após o período de teste. **O aplicativo gráfico não tem esse temporizador.**

Diagnóstico do aplicativo gráfico, iniciado explicitamente (captura real; requer autorização macOS):

```sh
open -a "$PWD/dist/MacMirror.app" --args --integration --tv 192.168.0.13 --seconds 120
```

Esse modo exibe o endereço/código temporário e métricas, encerra a transmissão após o teste e mantém a janela aberta. Inicie pelo Finder/`open` para que o macOS atribua a permissão ao MacMirror, sem exigir permissão do Terminal. Os eventos de estado e falha podem ser consultados com `log show --last 5m --info --predicate 'subsystem == "local.macmirror.app" AND process == "MacMirror"'`. A execução normal não inicia captura automaticamente. Não publique logs com códigos de sessões ainda ativas. Os testes `--export`/`--encode-file` exportam **somente a fonte sintética**; a interface não tem gravação de tela em disco permanente.

Com uma sessão iniciada pelo usuário e enviada por DLNA, o diagnóstico abaixo consulta somente métricas, timestamps e nível do AAC decodificado em memória. Não salva pixels, amostras de áudio nem o código ativo:

```sh
python3 scripts/validate-audio.py --tv 192.168.0.13
```

Somente a confirmação de audição na Samsung valida o som físico; codec e nível em um segmento não bastam.

## Arquitetura e comportamento

- `macos/Core/Capture.swift`: monitores ScreenCaptureKit, frame mais recente, três buffers de captura e fonte sintética testável. Preserva proporção com barras pretas.
- `CompatibilityCapture.swift`: rota pública AVFoundation (`AVCaptureScreenInput`) e conversão Core Image para canvas fixo sem distorção; pool limitado a cinco buffers. `AdaptiveScreenSource` prefere ScreenCaptureKit com recursos disponíveis, usa AVFoundation quando o espaço livre medido é menor que 10 GB e pode migrar para ela após o erro de sistema -3821. Esse valor é uma heurística deste aplicativo, motivada pelo comportamento observado, não um limite oficial do macOS. A troca exige que a sessão ainda esteja ativa e a permissão oficial continue concedida; não retoma cancelamento do usuário, bloqueio ou permissão negada.
- `Encoder.swift`: H.264 em hardware quando disponível; fallback explícito nas métricas, sem B-frames, keyframe a cada 0,5 s no modo Menor atraso ou 1 s no modo tolerante. Baseline 3.1 em 480p/720p; Main 4.0 em 1080p, condicionado à confirmação de capacidade pelo usuário.
- `Audio.swift`: captura pública Core Audio Process Tap, sem microfone ou alteração da saída padrão; dispositivo privado temporário com `mutedWhenTapped` (silencia a reprodução local somente durante a leitura do tap), ring limitado a 250 ms, estéreo Float32 e conversão para 48 kHz. Silêncio quando nenhum aplicativo produz som; sem arquivo de áudio permanente.
- `Muxer.swift`: H.264 nativo sem transcodificação → HLS MPEG-TS e TS contínuo. Com áudio, um processo normaliza os timestamps em NUT e outro multiplexa o vídeo com AAC-LC estéreo de 128 kbps. Isso corrige a falha do primeiro experimento de áudio com H.264 bruto. PCM passa por FIFO privado e fila limitada a 1 MB. Ambos os processos encerram na parada.
- `HTTPServer.swift`: Network.framework ligado a um IPv4 privado de interface física, aceitando pares da mesma sub-rede. Token aleatório de 64 bits por sessão em todos os endpoints de mídia. Até 32 conexões, 16 KB por cabeçalho, limite de 1 MB pendente por espectador TS, cache de entrada limitado a 512 KB e 0,15 s no modo Menor atraso (2 s no modo tolerante). HLS com seis segmentos de 1 s e dois segmentos adicionais para tolerância de download, substituição atômica e limpeza automática.
- `Discovery.swift`: SSDP/UPnP, descrição, formatos anunciados e SOAP AVTransport. Formatos anunciados não se tornam um selo de compatibilidade. Não há instalação automática de aplicativos na TV.
- `Session.swift`: exclusão de sessões simultâneas, inicialização transacional, watchdog, parada, recuperação por nova sessão. Descarta frames quando há três pendentes no encoder. Para a sessão se o pipeline atrasar mais de 2,5 segundos, evitando acumular atraso indefinidamente; sugere reduzir qualidade.
- `macos/Resources/MacMirror.icns`: ícone nativo em dez representações de 16 a 1024 pixels, renderizado por `scripts/generate-icon.swift` e integrado ao pacote pelo Xcode.
- `macos/App`: SwiftUI/dark mode, indicação de captura, métricas medidas. Suspensão, bloqueio e alteração de monitores encerram a sessão; retomar captura exige clicar novamente. Mudança de IP encerra e pede reinício para exibir endereço e token corretos.
- `receiver/web`: HTML5 HLS nativo, capacidade antes de reprodução, controle remoto, reconexão com espera crescente limitada a 30 s, watchdog de frames, tela cheia e proporção preservada.
- `receiver/tizen`: receptor funcional usando Samsung AVPlay quando instalado em modelo compatível. Projeto preparado, sem pacote assinado/instalação nesta sessão.

## Limitações conhecidas

- Captura de áudio exige macOS 14.2+, permissão oficial e saída estéreo Float32 compatível. Conteúdo protegido pode restringir captura. Não há captura de microfone. Não há HEVC, WebRTC, MSE/hls.js, Miracast ou tentativa de contornar restrições do macOS.
- HLS convencional e DLNA usam buffering. O usuário estimou atraso anterior superior a cinco segundos. Menor atraso reduz cache no Mac, intervalo entre keyframes e espera no multiplexador; o buffer interno do player DLNA da TV não é configurável por essa API. O relógio permite comparar o atraso visual; o aplicativo não inventa uma medição automática nem promete um segundo ou menos. HLS mantém segmentos de 1 s para compatibilidade com AVPlayer. A alternativa Tizen tenta buffer de 4 s pelo AVPlay, mas não foi instalada nem validada nessa TV.
- Bloqueio/suspensão, troca de IP e monitores exigem novo Iniciar. O receptor reconecta durante interrupções transitórias dentro da mesma sessão; o controlador DLNA consulta o estado, tenta retomar `STOPPED`/`NO_MEDIA_PRESENT` com backoff de até 30 s e respeita `PAUSED_PLAYBACK`; após Parar/reiniciar, o token muda e será necessário informar o novo código ou reenviar por DLNA.
- A rota AVFoundation de compatibilidade usa mais processamento para redimensionar/normalizar frames; o encoder H.264 continua em hardware quando disponível.
- O servidor usa HTTP sem criptografia, restrito à LAN. Use uma rede de confiança; o token protege contra acesso casual, mas não contra interceptação no Wi-Fi. Nenhuma porta de roteador ou túnel é configurada.
- Em falha abrupta do processo, o diretório temporário pode sobreviver até a limpeza do sistema. Paradas normais removem-no. A janela de segmentos permanece limitada durante a transmissão.
- Resolução/FPS são alvo de configuração; a interface mostra FPS e bitrate efetivamente medidos. “IPs ativos” conta espectadores por endereço nos últimos 12 s, não sessões TCP nem prova de reprodução.

Documentação técnica consultada: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps), [VideoToolbox](https://developer.apple.com/documentation/videotoolbox), [FFmpeg HLS](https://ffmpeg.org/ffmpeg-formats.html#hls), [Samsung AVPlay](https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html), [especificações Samsung 2020](https://developer.samsung.com/smarttv/develop/specifications/media-specifications/2020-tv-video-specifications.html).
