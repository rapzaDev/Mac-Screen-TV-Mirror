# Receptor Samsung AVPlay

O projeto em `receiver/tizen/` contém conexão por endereço, reprodução HLS AVPlay, letterbox, foco por setas, Enter, Voltar (10009), desconexão e reconexão. Usa `$WEBAPIS/webapis/webapis.js` da própria TV; não depende de CDN ou serviço externo.

A rede identificou **UN32T4300AGXZD**, Tizen, modelo interno `20_KANTS2_FHD_BASIC`. Isso justifica preparar AVPlay, mas não prova que a instalação de desenvolvimento esteja habilitada. O SDK/CLI Tizen e certificados não estão disponíveis neste Mac; nenhum `.wgt` assinado foi produzido nem instalado.

## Instalação opcional — depende de ações físicas e ferramentas

1. Confirme primeiro se o DLNA do MacMirror ou o navegador da TV já reproduz o vídeo. Só siga este caminho se necessário.
2. Instale **Tizen Studio**, a extensão **Samsung TV** e **Samsung Certificate Extension**, pelas fontes oficiais. Esse procedimento não foi executado automaticamente e requer sua autorização.
3. Crie um perfil de certificado Samsung TV no Certificate Manager. Normalmente exige conta Samsung e incluir o DUID da TV no certificado de distribuidor. Não coloque certificados, senhas ou chaves no repositório.
4. Na TV compatível, abra **Apps** e digite **12345** pelo controle/teclado. Na tela de Developer Mode, habilite-o e informe o IP do Mac; reinicie a TV quando solicitado. A disponibilidade desse menu depende do firmware e da região. Não altere configurações ocultas de serviço.
5. No Device Manager/Remote Device Manager, adicione o IPv4 da TV e conecte (porta de desenvolvimento normalmente 26101); confirme o estado conectado e o DUID. Se houver “Permit to install applications”, execute para esta TV com seu certificado.
6. Na raiz deste projeto, execute `./scripts/package-tizen.sh NOME_DO_PERFIL`. O script compila o Web App e assina com o perfil existente; não instala nada. Alternativamente, importe `receiver/tizen` como projeto Web no Tizen Studio e use Build/Signed Package.
7. Após autorização explícita para instalar, use o Tizen Studio para **Run As → Tizen Web Application** na TV conectada, ou `tizen install -n ARQUIVO.wgt -t NOME_DO_ALVO -- dist/tizen`. Para iniciar por CLI: `tizen run -p MacMirror1.Receiver -t NOME_DO_ALVO`.
8. Abra MacMirror no Mac e inicie a captura. No receptor Tizen, informe o endereço completo mostrado no Mac, por exemplo `http://192.168.0.12:8787/tv#CÓDIGO`. O receptor converte-o para a playlist com token. Use Enter para conectar.
9. Confirme imagem em movimento, mantenha a transmissão por vários minutos, interrompa temporariamente a rede e observe a reconexão. Após uma nova sessão do Mac, informe o novo código.

O `config.xml` declara perfil `tv-samsung`, Tizen >=4.0, privilégio `internet` e acesso de rede para alcançar o Mac. A validação de endereço no receptor restringe entradas a IPv4 privados. Não declara privilégios antigos de AVPlay: a Samsung informa que o privilégio específico não é usado em TV Web Apps desde modelos 2015. O receptor não usa DRM.

Referências oficiais: [TV Development](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk.html), [conectar TV ao SDK](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html), [certificados](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/creating-certificates.html), [AVPlay](https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html).
