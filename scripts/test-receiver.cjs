// Receiver state-machine tests; media decoding is independently verified with AVPlayer and FFmpeg.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const code = fs.readFileSync('receiver/web/receiver.js', 'utf8');
function setup(hls = true, hash = '') {
  const nodes = {}, timers = new Map(); let next = 1;
  for (const id of ['video','panel','status','badge','address','connect','addressLabel','playControls','capability','start','retry','full','sound','disconnect','avplayer']) {
    nodes[id] = { className: '', style: {}, value: '', textContent: '', offsetParent: {}, focus() {}, querySelectorAll() { return []; } };
  }
  const handlers = {};
  Object.assign(nodes.video, { currentTime: 0, playCalls: 0, paused: false, canPlayType: () => hls ? 'maybe' : '',
    play() { this.playCalls++; return { catch() {} }; }, pause() { this.paused = true; }, load() {}, removeAttribute(n) { delete this[n]; },
    addEventListener(e, fn) { handlers[e] = fn; } });
  const context = { document: { getElementById: id => nodes[id], addEventListener() {}, documentElement: {} }, location: { protocol: 'http:', host: '192.168.0.12:8787', hash: hash },
    window: { addEventListener() {} }, console, Date, setInterval() {},
    setTimeout(fn, delay) { const id = next++; timers.set(id, {fn, delay}); return id; }, clearTimeout(id) { timers.delete(id); } };
  vm.runInNewContext(code, context);
  return { nodes, timers, handlers };
}
{
  const {nodes:n, timers, handlers} = setup();
  n.address.value = '0123456789abcdef'; n.start.onclick();
  assert.equal(n.video.src, 'http://192.168.0.12:8787/s/0123456789abcdef/live.m3u8'); assert.equal(n.video.playCalls, 1);
  handlers.playing(); assert.equal(n.panel.className, 'hidden');
  n.video.error = {code: 2}; handlers.error(); assert.equal(timers.size, 1);
  let [id, retry] = [...timers][0]; timers.delete(id); retry.fn(); assert.equal(n.video.playCalls, 2);
  handlers.error(); n.disconnect.onclick(); assert.equal(timers.size, 0); assert.equal(n.video.src, undefined);
  handlers.error(); assert.equal(timers.size, 0); // Stop must prevent reconnection.
}
{
  const {nodes:n} = setup(false); n.address.value = '0123456789abcdef'; n.start.onclick();
  assert.equal(n.video.playCalls, 0); assert.match(n.status.textContent, /HLS nativo indisponível/);
}
{
  const {nodes:n} = setup(); n.address.value = 'http://8.8.8.8:8787/tv#0123456789abcdef'; n.start.onclick();
  assert.equal(n.video.playCalls, 0);
  n.address.value = 'http://192.168.0.12:8787/tv#0123456789abcdef'; n.start.onclick(); assert.equal(n.video.playCalls, 1);
}
{
  const {nodes:n, handlers} = setup(true, '#0123456789abcdef&muted=1');
  assert.equal(n.video.muted, true); n.sound.onclick(); assert.equal(n.video.muted, true);
  assert.equal(n.sound.disabled, true);
  n.video.paused = false; n.video.currentTime = 1;
  n.video.seekable = { length: 1, start: () => 0, end: () => 8 };
  handlers.timeupdate(); assert.equal(n.video.currentTime, 7);
}
console.log('Receiver: 4 cenários passaram (conexão, reconexão/parada, capacidade e validação de endereço).');
