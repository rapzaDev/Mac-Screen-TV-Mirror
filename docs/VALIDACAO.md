# Relatório de validação — 27/10/2026

**FUNCIONAL NA SAMSUNG: imagem real, som exclusivo na TV durante o espelhamento e retorno ao Mac após Parar confirmados pelo usuário. Ícone nativo integrado e reconhecido pelo macOS.**

O usuário confirmou fisicamente captura real e retorno após interrupção na Samsung durante a validação inicial com ScreenCaptureKit. O sistema depois encerrou essa captura sob pressão de recursos. A versão atual com AVFoundation passou pelo teste prolongado de seis minutos, com reprodução HTTP e TV em PLAYING; o usuário posteriormente confirmou a imagem nessa rota ao relatar que vídeos apareciam na TV, porém sem som. A execução normal não tem temporizador.

## Ambiente e entrega

- macOS 26.3.1, Apple Silicon, Xcode 26.2, Swift 6.2.3 (fontes em modo Swift 5).
- `dist/MacMirror.app`: aplicativo universal arm64/x86_64 compilado pelo Xcode e assinado ad hoc. Execução testada em arm64. Não notarizado.
- FFmpeg 9.0.2 já existente em `/opt/homebrew/bin/ffmpeg`; nenhuma instalação de ferramenta de sistema/TV foi realizada.
- LAN: Mac `192.168.0.12`, Samsung `192.168.0.13`. SSDP, descrição DMR e API HTTP identificaram **UN32T4300AGXZD**, Tizen, painel 1366×768, serviços AVTransport/ConnectionManager e H.264/TS anunciado.

## Evidências locais concluídas

| Verificação | Resultado |
|---|---|
| Xcode Release / assinatura | BUILD SUCCEEDED; `codesign --verify --deep --strict` aprovado |
| XCTest | 12 testes, zero falhas; inclui letterbox, limite de pool e liberação da captura de compatibilidade |
| Receptor JavaScript | 3 cenários passaram; sintaxe web/Tizen válida |
| Fonte sintética → VideoToolbox | 120 frames H.264 Baseline 3.1, aceleração por hardware confirmada |
| Transmissão contínua sintética | 120 s; playlist avançou da sequência 0 para 111 durante a amostragem |
| Memória do produtor sintético | RSS entre 36.128 e 38.048 KiB; sem crescimento ilimitado observado nesse intervalo |
| Segmentação | No máximo 8 arquivos TS observados; cada segmento inspecionado com 30 frames e keyframe inicial |
| Timestamps | PTS/DTS em ordem; incremento de 1/30 s; SAR 1:1 |
| Cliente nativo AVPlayer | 746 frames apresentados em 26,322 s de mídia a 1280×720 |
| Cliente FFmpeg HTTP TS | Decodificou 446 frames / aproximadamente 15 s, sem falha |
| Novo cliente HTTP HLS | Decodificou 240 frames / 8 s após a saída do primeiro cliente |
| Parada | Porta fechada e diretório temporário removido |
| Reinício | Dois ciclos completos no mesmo objeto de sessão, sem reiniciar o programa |
| Erros / cancelamento | Testados encoder encerrado, falha forçada do FFmpeg, Stop durante preparação e qualidade 1080p sem confirmação |
| Segurança HTTP | Token ausente/incorreto negado, range parcial correto e segmentos TS com pacotes de 188 bytes |

Evidências reproduzíveis: `artifacts/tests.log`, `artifacts/test-full.log`, `artifacts/xcode-build.log`, `artifacts/integration-summary.json`, `artifacts/soak.log`, `artifacts/soak-avplayer.log`, `artifacts/soak-ts-decode.log`, `artifacts/soak-hls-rejoin.log`. Esses logs pertencem aos testes sintéticos. Não confundir com captura real.

## Captura real e Samsung

- O usuário concedeu permissão oficial de gravação de tela. A redefinição oficial restrita a `local.macmirror.app` foi executada com autorização explícita e resolveu a autorização antiga incompatível.
- Um print fornecido pelo usuário mostrou captura real com 194 frames, 1280×720, 30,6 FPS, 1,13 Mbps medidos, encoder por hardware e zero descartes naquele instante. Isso comprova captura/codificação real naquele teste, sem comprovar estabilidade prolongada.
- O usuário confirmou fisicamente **barras coloridas e quadrado em movimento na Samsung**. A fonte desse teste era sintética; não se trata de confirmação da tela real.
- A Samsung efetivamente requisitou `/live.ts`, aceitou SetAVTransportURI/Play e informou PLAYING. Outros momentos mostraram PAUSED_PLAYBACK/STOPPED. Na validação final, a captura real manteve `PLAYING` em todas as 20 consultas durante 40 s; após uma interrupção controlada, houve retomada automática em 11,7 s. O usuário confirmou que a tela real voltou e continuou se movendo na TV.
- HLS via AVTransport foi recusado com UPnP 714 (`Illegal MIME-type`). Por isso o padrão usa MPEG-TS direto no DLNA. O receptor HLS web/Tizen permanece como alternativa.
- O teste real revelou parada por fluxo de ciclo de vida. Foi corrigido o encerramento incondicional ao receber notificação de monitor: só mudanças reais de lista/resolução interrompem a sessão. Logs agora registram o motivo de encerramento. A versão corrigida foi validada fisicamente e permaneceu ativa após a correção.
- O lançamento direto do binário pelo shell atribuía a autorização ao Terminal. Abrir o `.app` pelo Finder/LaunchServices resolve essa atribuição. Após recompilações ad hoc, o macOS pode exigir renovar a entrada de permissão. Os logs confirmaram `Failed to match existing code requirement` entre o hash salvo e o atual, mesmo com o botão habilitado. A redefinição oficial restrita a `local.macmirror.app` foi executada após autorização explícita. Nenhuma alteração global de privacidade foi realizada.

### Validação final com frames reais

- Aplicativo gráfico normal, aberto por LaunchServices, sem `--synthetic` e sem temporizador de teste. Captura ScreenCaptureKit da tela inteira.
- HLS real inspecionado em memória: 1280×720, 30/1 FPS, 30 frames por segmento, keyframe inicial, PTS em ordem. Nenhum segmento real foi exportado como arquivo permanente.
- AVPlayer apresentou **894 frames reais / 31,554 s de mídia**, em 1280×720.
- Um novo cliente FFmpeg HTTP HLS decodificou **300 frames / 10 s** após a reconexão, sem erro.
- O controlador de teste enviou um único DLNA Stop. O aplicativo retomou sozinho em **11,7 s**, e o usuário confirmou: “Sim, voltou e continua funcionando”. Esse tempo é de reconexão, não latência de vídeo.
- O usuário também testou Parar → Iniciar pela interface e confirmou que o espelhamento funcionou.
- Evidências sem pixels ou tokens ativos: `artifacts/real-summary.json`, `artifacts/real-validation.log`, `artifacts/real-avplayer.log`, `artifacts/real-http-decode.log`, `artifacts/real-session-events.log`.
- Às 16:43:56, depois da confirmação física, o ScreenCaptureKit notificou `systemStoppedStream` (-3821) e a transmissão encerrou. O usuário confirmou que não a interrompeu manualmente.
- No mesmo instante, `replayd` registrou `cacheDeleteUrgencyHigh`, `handleMemoryWarningForCurrentActiveSession` e `stopAllStreamsWithError`. O volume estava 97% ocupado, com aproximadamente 6,5 GiB livres; a memória do sistema mostrou 49% livre na inspeção posterior. A evidência aponta para pressão de armazenamento/recursos como causa da interrupção do serviço Apple. Não é um temporizador de assinatura ou do MacMirror.
- Foi solicitada liberação manual de espaço, mas o usuário não podia fazê-la naquela sessão. Nenhum arquivo pessoal ou Archive do Xcode foi excluído. Foi então implementada e compilada a rota AVFoundation de compatibilidade; a sessão de compatibilidade usou essa rota no teste concluído. Logs da interrupção anterior em `artifacts/system-stop.log`.
- Após o evento, a sessão ScreenCaptureKit encerrou com erro. Depois da implementação da alternativa, uma nova sessão AVFoundation foi iniciada pelo usuário e passou pelo monitor de continuidade de seis minutos; a preferência por ScreenCaptureKit permanece para ambientes com recursos disponíveis.

Aguarde a descoberta terminar e confirme a Samsung selecionada antes de iniciar. A reprodução física foi validada pelo DLNA da TV; não foi necessário instalar o receptor Tizen.

## Limites de validação

Sem medição confiável de latência ponta a ponta; sem benchmark de horas de transmissão; sem execução Intel; sem teste de monitor externo, suspensão ou troca de IP físicos. Os caminhos de recuperação existem no código, mas não recebem selo de validação física por terem compilado. O build anterior era somente vídeo. O áudio acrescentado nesta revisão tem validação separada abaixo. Não há pacote Tizen assinado, certificado configurado ou instalação na TV. Não havia navegador conectado à automação; a reprodução HLS foi verificada por AVPlayer/FFmpeg e a lógica do receptor por testes JS.

## Validação da versão com captura de compatibilidade

O disco permaneceu com 97% de ocupação e cerca de 6,5 GiB livres. A versão atual escolheu `AVFoundation · compatibilidade`, o que foi confirmado pelo print do usuário e pelo log nativo `backend=AVFoundation reason=compatibility_or_low_disk`.

- No print: 1280×720, **29,8 FPS**, **1,65 Mbps**, encoder por hardware, 312 frames e zero descartes pelo encoder naquele instante.
- Cliente AVPlayer: **896 frames reais / 31,641 s de mídia**.
- Nova interrupção controlada por DLNA Stop: retomada automática em **11,34 s**.
- Monitor de continuidade: **360 s de amostragem**, 37 consultas com a TV em `PLAYING`, playlist avançando da sequência **102 para 462**, sem encerramento da captura. A sessão já estava ativa antes do início desse monitor.
- RSS do aplicativo entre **125.168 e 133.280 KiB** (aproximadamente 122–130 MiB), sem crescimento contínuo observado.
- Ao final do monitor, outro cliente decodificou **240 frames em 8 s**, com **223 imagens decodificadas distintas**; apenas a contagem dos hashes foi retida, sem gravar pixels reais.
- As permissões continuaram sendo concedidas pelo mecanismo oficial do macOS. Nenhuma proteção do sistema foi desabilitada, e nenhum arquivo pessoal foi apagado.

Evidências: `artifacts/compatibility-real-summary.json`, `artifacts/compatibility-validation.log`, `artifacts/compatibility-watch-summary.json`, `artifacts/compatibility-watch.log` e `artifacts/app-manifest.json`. O rótulo de origem do validador genérico foi corrigido para a API efetivamente usada; os dados brutos de decodificação/tempo foram preservados em `compatibility-raw-summary.json`.

Este teste excedeu o período da falha anterior. Não houve teste de horas de duração, e ele não representa uma garantia contra qualquer interrupção do sistema operacional.


## Revisão de áudio e menor atraso

O usuário relatou imagem real na Samsung, ausência de som (o build anterior era somente vídeo) e atraso estimado **superior a cinco segundos**. Essa é uma estimativa humana, não uma medição instrumental.

Implementado: Core Audio Process Tap público, captura de saída dos aplicativos sem microfone, conversão estéreo 48 kHz, AAC-LC 128 kbps multiplexado com o H.264 nativo. O dispositivo agregado é privado, temporário e não altera a saída padrão. Nenhum driver foi instalado. Parar encerra o tap, o dispositivo, o encoder e ambos os processos FFmpeg. A autorização continua pelo mecanismo oficial do macOS.

O modo Menor atraso usa keyframes de 0,5 s, cache de entrada TS de 0,15 s e pacotes TS descarregados sem espera adicional de PES. Cabeçalhos DLNA identificam corretamente transmissão ao vivo sem seek. O buffer interno do receptor DLNA não é controlado por AVTransport. O receptor HLS tenta voltar à ponta ao ficar mais de três segundos atrás; o receptor Tizen tenta o mínimo documentado de quatro segundos pelo AVPlay, sujeito à plataforma. Tizen não foi instalado nesta sessão.

A prova com cliente nativo encontrou `EXT-X-TARGETDURATION:0` quando o FFmpeg 9 segmentava em 0,5 s; AVPlayer recusou essa playlist. Por isso HLS mantém segmentos de 1 s, enquanto TS/DLNA mantém keyframes de 0,5 s. O teste automatizado agora exige target duration válido.

- XCTest: 16 casos, incluindo overflow/silêncio do ring, conversão de 44,1 para 48 kHz, presença efetiva de tom no AAC, PTS A/V em ordem e próximos, keyframes, parada com áudio pendente e remoção dos recursos.
- JavaScript: quatro cenários, incluindo prévia local sem som e retorno ao ponto ao vivo; sintaxe web/Tizen verificada.
- As provas sintéticas não comprovam captura do áudio real nem audição física na Samsung. Essas etapas exigem o usuário autorizar a revisão e reproduzir som de um aplicativo.

Evidências desta revisão: `artifacts/audio-tests-full.log`, `artifacts/audio-app-build.log`, `artifacts/audio-soak.log`, `artifacts/audio-soak-avplayer.log`, `artifacts/audio-soak-decode.log`. As provas sintéticas são identificadas como tais. Os resultados finais de execução são acrescentados após a verificação.


### Resultados locais da revisão audiovisual

- Xcode Release universal: compilado e assinatura ad hoc verificada em `dist/MacMirror.app`.
- 16 testes Swift e quatro cenários JavaScript concluídos, zero falhas.
- Prova sintética de áudio e vídeo durante **65 s**, com aproximadamente 30 FPS e zero descartes reportados pelo encoder; limpeza concluída ao parar.
- AVPlayer: **653 frames / 23,041 s de mídia**, 1280×720, reprodução contínua pelo HTTP HLS corrigido.
- FFmpeg: **439 frames / 15 s**, áudio e vídeo decodificados do endpoint TS HTTP.
- Oito segmentos sintéticos mantidos no fim do teste; 30 frames por segmento, PTS de ambas as faixas estritamente crescentes. Diferença entre PTS A/V nas bordas menor que **31 ms**. Isso verifica a linha de tempo do transporte, não a latência física ou sincronismo labial na TV.
- AAC decodificado do teste sintético com nível RMS de **-19,54 dBFS**, comprovando tom codificado, em vez de faixa silenciosa. O tom sintético não foi tocado pelos alto-falantes do Mac.
- Evidência consolidada: `artifacts/audio-soak-summary.json`. A primeira tentativa HLS com target duration zero foi corrigida antes desse resultado.
- A versão atual foi aberta por LaunchServices para o usuário iniciar a sessão e conceder as permissões oficiais. Captura de áudio real e audição na TV ainda aguardam essa execução.


## Confirmação audiovisual e revisão de ícone/saída de som

O usuário confirmou que a revisão audiovisual funcionou e descreveu ouvir os vídeos tanto no Mac quanto na TV. Essa observação confirma áudio físico na Samsung, além da imagem. Não comprova redução medida da latência: não foi informado um novo valor após a revisão.

A revisão seguinte usa a API pública `CATapMuteBehavior.mutedWhenTapped`. Segundo a documentação Apple e o header do SDK, o áudio continua sendo capturado e a saída local do processo capturado é silenciada somente enquanto um cliente lê o tap. Parar encerra/destroi o tap e o dispositivo privado; o volume e a seleção de saída padrão não são modificados. A reprodução local volta quando o tap deixa de ser lido. O usuário confirmou fisicamente esta revisão: “Sim, somente na TV; ao parar volta ao Mac”.

Ícone criado como desenho vetorial nativo AppKit, exportado em dez representações PNG de 16 a 1024 pixels e empacotado em `macos/Resources/MacMirror.icns`. Xcode inclui o recurso e Info.plist referencia `CFBundleIconFile`. Prévia de 1024 pixels inspecionada visualmente. O script de build regenera o ícone sem dependências externas.

Testes desta revisão: `artifacts/icon-audio-tests.log`; build: `artifacts/icon-audio-build.log` e `artifacts/xcode-build.log`. A atualização mantém os testes de lifecycle, cancelamento e liberação dos recursos. Nenhuma configuração global de áudio foi alterada.

Referência: [CATapMuteBehavior — Apple](https://developer.apple.com/documentation/coreaudio/catapmutebehavior).


### Aceite da revisão de ícone e saída exclusiva

- Usuário confirmou: **“Sim, somente na TV; ao parar volta ao Mac”**.
- Ícone reconhecido pelo `NSWorkspace`/Finder; prévia efetivamente retornada pelo macOS inspecionada em `artifacts/registered-app-icon.png`.
- 16 testes Swift e quatro cenários JavaScript aprovados; Xcode Release universal compilado e `codesign --verify --deep --strict` aprovado.
- Nenhuma nova recompilação após essa confirmação. Pacote validado: `/Users/ti/Documents/espelhamento_tela/dist/MacMirror.app`.
- Classificação: **FUNCIONAL NA SAMSUNG** para imagem e áudio, incluindo saída exclusiva durante a transmissão e restauração da reprodução local ao parar. O atraso físico após o modo Menor atraso continua sem novo valor medido informado.
