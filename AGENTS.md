# MacMirror
- Responda em português. Preserve a privacidade e a captura iniciada explicitamente.
- Código operacional em `macos/Core`; UI em `macos/App`; testes SwiftPM em `macos/Tests`.
- `./scripts/build.sh` gera o projeto Xcode e `dist/MacMirror.app`; `./scripts/test.sh` verifica o núcleo e a sintaxe dos receptores.
- Não confunda vídeo sintético, decodificação local, estado DLNA e imagem observada na Samsung.
- Só declare compatibilidade física depois de confirmação do usuário. Não instale SDK, ferramentas ou pacotes na TV sem autorização.
- Não grave frames reais permanentemente, não registre tokens de produção e não exponha o servidor fora da LAN.
- Ao alterar as fontes, gere novamente o Xcode com `python3 scripts/generate-xcode.py`.
