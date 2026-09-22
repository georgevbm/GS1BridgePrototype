# Instalar a build de teste no iPhone sem Apple Developer Program pago

Este projeto pode ser testado em um iPhone físico usando uma Conta Apple gratuita. O fluxo é:

1. Codemagic compila um `.ipa` **não assinado** para iPhone físico.
2. No Windows, o Sideloadly assina esse `.ipa` com a sua Conta Apple gratuita.
3. O Sideloadly instala o app no iPhone via USB e pode renovar a assinatura periodicamente.

## Limitações da conta gratuita da Apple

- O perfil de desenvolvimento expira após 7 dias.
- É possível ter até 3 apps de desenvolvimento instalados por dispositivo com a Personal Team.
- O app precisa ser renovado/reassinado periodicamente.
- TestFlight/App Store Connect exigem Apple Developer Program pago; não são usados neste fluxo.

## Parte A — gerar o IPA no Codemagic

1. Coloque este projeto em um repositório Git.
2. Conecte o repositório ao Codemagic.
3. Inicie o workflow `GS1 iPhone unsigned build`.
4. Aguarde `Run protocol tests`, `Generate Xcode project` e `Build unsigned app for physical iPhone` concluírem.
5. Na seção Artifacts do build, baixe `GS1Bridge-unsigned.ipa`.

Esse arquivo ainda não está assinado; é proposital.

## Parte B — instalar via Sideloadly no Windows

1. Instale o Sideloadly para Windows pelo site oficial.
2. O Sideloadly atualmente orienta usar as versões do iTunes e iCloud baixadas diretamente da Apple no Windows (não as versões Microsoft Store).
3. Conecte o iPhone ao PC por cabo USB, desbloqueie-o e toque em `Confiar` se solicitado.
4. Abra o Sideloadly.
5. Arraste `GS1Bridge-unsigned.ipa` para a janela.
6. Selecione o seu iPhone.
7. Informe uma Conta Apple válida para o provisionamento gratuito.
8. Inicie o sideload e conclua a autenticação solicitada.
9. No iPhone, habilite Modo Desenvolvedor em `Ajustes > Privacidade e Segurança > Modo Desenvolvedor`, caso seja solicitado. O iPhone reinicia durante a ativação.
10. Abra `GS1 Debug` no iPhone.

## Primeiro teste BLE

Antes de tocar em `Escanear e conectar` no protótipo:

1. Abra o app SIBIONICS e confirme uma leitura recente.
2. Anote a glicemia apenas para comparação posterior.
3. Desligue temporariamente o Bluetooth do iPhone em `Ajustes > Bluetooth` para liberar o GS1, aguarde alguns segundos e ligue novamente quando for iniciar o protótipo.
4. No `GS1 Debug`, informe o endereço BLE que você descobriu no Windows.
5. Inicie o scan/conexão.

O marco de sucesso da V0.1 é o app mostrar conexão e receber um frame válido do sensor. Não use os números exibidos pelo protótipo para dose de insulina ou outra decisão de tratamento; a camada final de calibração ainda está em desenvolvimento.

## Renovação

Com uma Conta Apple gratuita, a assinatura dura 7 dias. O Sideloadly oferece renovação automática quando o PC e o iPhone estão disponíveis para o processo de refresh. Durante desenvolvimento ativo, também é possível simplesmente reinstalar a próxima build.
