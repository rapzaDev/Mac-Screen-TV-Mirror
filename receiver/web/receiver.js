(function () {
'use strict';
var video = document.getElementById('video'), panel = document.getElementById('panel'), status = document.getElementById('status'), badge = document.getElementById('badge');
var address = document.getElementById('address'), av = window.webapis && window.webapis.avplay;
var localPreview = location.hash.indexOf('muted=1') >= 0;
video.muted = localPreview;
var sound = document.getElementById('sound');
sound.textContent = video.muted ? 'Som: desligado' : 'Som: ligado';
if (localPreview) { sound.disabled = true; sound.textContent = 'Prévia no Mac: sem som'; }
sound.onclick = function () { if (localPreview) { return; } video.muted = !video.muted; sound.textContent = video.muted ? 'Som: desligado' : 'Som: ligado'; };
if (av) { sound.className = 'hidden'; }
var lastLiveCorrection = 0;
var url = '', retryTimer = null, attempts = 0, active = false, lastTime = -1, lastProgress = Date.now(), preparing = false;
function text(message) { status.textContent = message; badge.textContent = message; }
function show(message) { panel.className = ''; badge.className = 'hidden'; text(message); }
function hide() { panel.className = 'hidden'; badge.className = 'hidden'; }
function release() {
    if (av) { try { av.stop(); } catch (e) {} try { av.close(); } catch (e) {} }
    else { video.pause(); video.removeAttribute('src'); video.load(); }
    preparing = false;
}
function reconnect(reason) {
    if (!active || retryTimer) { return; }
    preparing = false;
    show(reason + ' Tentando reconectar…');
    retryTimer = setTimeout(function () { retryTimer = null; play(); }, Math.min(30000, 1000 * Math.pow(2, Math.min(attempts++, 5))));
}
function avRect() { if (av) { try { av.setDisplayRect(0, 0, 1920, 1080); av.setDisplayMethod('PLAYER_DISPLAY_MODE_LETTER_BOX'); } catch (e) {} } }
function play() {
    if (!active || !url || preparing) { return; }
    release(); preparing = true; lastProgress = Date.now(); lastTime = -1;
    text('Carregando vídeo ao vivo…'); panel.className = ''; document.getElementById('playControls').style.display = 'block';
    if (av) {
        document.getElementById('avplayer').className = ''; video.className = 'hidden';
        try {
            av.open(url); avRect();
            // Samsung documents a minimum of four seconds; unsupported firmware keeps its default.
            try {
                av.setBufferingParam('PLAYER_BUFFER_FOR_PLAY', 'PLAYER_BUFFER_SIZE_IN_SECOND', 4);
                av.setBufferingParam('PLAYER_BUFFER_FOR_RESUME', 'PLAYER_BUFFER_SIZE_IN_SECOND', 4);
            } catch (bufferError) {}
            av.setListener({
                onbufferingstart: function () { badge.className = ''; badge.textContent = 'Carregando…'; },
                onbufferingcomplete: function () { badge.className = 'hidden'; },
                oncurrentplaytime: function (ms) { if (ms !== lastTime) { lastTime = ms; lastProgress = Date.now(); attempts = 0; hide(); } },
                onstreamcompleted: function () { reconnect('A transmissão terminou.'); },
                onerror: function (e) { reconnect('AVPlay: ' + e); }
            });
            av.prepareAsync(function () { preparing = false; avRect(); av.play(); }, function (e) { reconnect('AVPlay não conseguiu abrir o HLS: ' + (e && e.message || e)); });
        } catch (e) { reconnect('Falha AVPlay: ' + e.message); }
    } else {
        var support = video.canPlayType('application/vnd.apple.mpegurl') || video.canPlayType('application/x-mpegURL');
        document.getElementById('capability').textContent = support ? 'HLS anunciado pelo navegador. A reprodução efetiva será verificada pelo avanço do vídeo.' : 'Este navegador não anuncia HLS nativo. Use o receptor Tizen AVPlay ou a conexão DLNA pelo Mac.';
        if (!support) { preparing = false; active = false; show('HLS nativo indisponível neste navegador. Veja o caminho Tizen no README.'); return; }
        video.src = url; preparing = false;
        var promise = video.play();
        if (promise && promise.catch) { promise.catch(function (e) { show('Selecione Reproduzir no controle remoto. ' + e.message); }); }
    }
}
function connect() {
    var value = address.value.replace(/^\s+|\s+$/g, '');
    if (/^[a-f0-9]{16}$/i.test(value) && location.protocol === 'http:') { url = location.protocol + '//' + location.host + '/s/' + value + '/live.m3u8'; }
    else {
        var match = value.match(/^(http:\/\/(?:10\.[0-9.]+|192\.168\.[0-9.]+|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9.]+):[0-9]+)\/(?:tv#|s\/)([a-f0-9]{16})(?:\/live\.m3u8)?$/i);
        if (!match) { show('Informe o código de 16 caracteres ou o endereço http://IP:8787/tv#código exibido no Mac.'); return; }
        url = match[1] + '/s/' + match[2] + '/live.m3u8';
    }
    clearTimeout(retryTimer); retryTimer = null; attempts = 0; active = true; play();
}
video.addEventListener('playing', function () { attempts = 0; lastProgress = Date.now(); hide(); });
video.addEventListener('timeupdate', function () {
    if (!video.paused && video.seekable && video.seekable.length && Date.now() - lastLiveCorrection > 5000) {
        var end = video.seekable.end(video.seekable.length - 1), begin = video.seekable.start(video.seekable.length - 1);
        if (end - video.currentTime > 3) { lastLiveCorrection = Date.now(); try { video.currentTime = Math.max(begin, end - 1); } catch (e) {} }
    }
    if (video.currentTime !== lastTime) { lastTime = video.currentTime; lastProgress = Date.now(); hide(); } });
video.addEventListener('error', function () { reconnect('Não foi possível reproduzir o vídeo (código ' + (video.error && video.error.code) + ').'); });
video.addEventListener('ended', function () { reconnect('A transmissão foi interrompida.'); });
video.addEventListener('waiting', function () { if (active) { badge.className = ''; badge.textContent = 'Aguardando vídeo…'; } });
setInterval(function () { if (active && Date.now() - lastProgress > 15000) { lastProgress = Date.now(); reconnect('Sem novos frames. Verifique o Mac e a rede.'); } }, 2000);
document.getElementById('start').onclick = connect;
document.getElementById('retry').onclick = function () { if (!url) { connect(); return; } clearTimeout(retryTimer); retryTimer = null; preparing = false; active = true; play(); };
document.getElementById('disconnect').onclick = function () { active = false; clearTimeout(retryTimer); retryTimer = null; release(); show('Desconectado. Inicie outra sessão pelo Mac.'); };
document.getElementById('full').onclick = function () { var root = document.documentElement; if (root.requestFullscreen) { root.requestFullscreen(); } else if (video.webkitEnterFullscreen) { video.webkitEnterFullscreen(); } };
document.addEventListener('keydown', function (e) {
    if (e.keyCode === 10009 || e.keyCode === 27) { if (panel.className === 'hidden') { show('Transmissão ao vivo'); document.getElementById('retry').focus(); } else { hide(); } e.preventDefault(); }
    if (e.keyCode === 13 && document.activeElement === address) { connect(); }
    if (e.keyCode >= 37 && e.keyCode <= 40 && document.activeElement !== address) {
        var controls = panel.querySelectorAll('input,button'), visible = [], i;
        for (i = 0; i < controls.length; i++) { if (controls[i].offsetParent !== null) { visible.push(controls[i]); } }
        var index = visible.indexOf(document.activeElement), delta = e.keyCode === 37 || e.keyCode === 38 ? -1 : 1;
        if (visible.length) { visible[(index + delta + visible.length) % visible.length].focus(); } e.preventDefault();
    }
});
window.addEventListener('resize', avRect);
window.addEventListener('unload', function () { active = false; release(); });
if (av) { document.getElementById('addressLabel').textContent = 'Endereço completo do receptor exibido no Mac'; document.getElementById('capability').textContent = 'Samsung AVPlay disponível neste aplicativo.'; }
var hash = location.hash.substring(1).split('&')[0]; if (/^[a-f0-9]{16}$/i.test(hash)) { address.value = hash; connect(); } else { address.focus(); }
})();
