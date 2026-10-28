#!/usr/bin/env python3
"""Validate an already user-started live session. Never saves screen pixels or session tokens.
--interrupt issues one DLNA Stop to test the app's automatic reconnection.
"""
import argparse,json,pathlib,re,subprocess,time,urllib.request,xml.etree.ElementTree as E
ROOT=pathlib.Path(__file__).resolve().parents[1]; ART=ROOT/'artifacts'; ART.mkdir(exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--tv',default='192.168.0.13');p.add_argument('--interrupt',action='store_true');p.add_argument('--backend',default='unknown (check GUI)');args=p.parse_args()
ns='urn:schemas-upnp-org:service:AVTransport:1'
def soap(action):
 b='<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:'+action+' xmlns:u="'+ns+'"><InstanceID>0</InstanceID></u:'+action+'></s:Body></s:Envelope>'
 r=urllib.request.Request('http://'+args.tv+':9197/upnp/control/AVTransport1',data=b.encode(),headers={'Content-Type':'text/xml; charset="utf-8"','SOAPAction':'"'+ns+'#'+action+'"'})
 return E.fromstring(urllib.request.urlopen(r,timeout=5).read())
def field(xml,name): return next((n.text for n in xml.iter() if n.tag.split('}')[-1]==name),'')
def state(): return field(soap('GetTransportInfo'),'CurrentTransportState')
uri=field(soap('GetMediaInfo'),'CurrentURI')
assert re.match(r'^http://(?:192\.168\.|10\.|172\.(?:1[6-9]|2\d|3[01])\.)[^/]+/s/[a-f0-9]{16}/live\.(ts|m3u8)$',uri),'A TV não aponta para uma sessão MacMirror'
hls=uri.rsplit('/',1)[0]+'/live.m3u8'
playlist=urllib.request.urlopen(hls,timeout=5).read().decode();names=[n for n in playlist.splitlines() if n.endswith('.ts')]
assert 1<=len(names)<=6
# Read one segment into RAM, inspect only metadata, then discard its bytes.
segment=urllib.request.urlopen(hls.rsplit('/',1)[0]+'/'+names[-1],timeout=5).read()
packet=json.loads(subprocess.check_output(['/opt/homebrew/bin/ffprobe','-v','error','-show_packets','-show_streams','-of','json','pipe:0'],input=segment)); del segment
video=[v for v in packet['packets'] if v['codec_type']=='video'];pts=[float(v['pts_time']) for v in video]
assert len(video)>=24 and all(b>a for a,b in zip(pts,pts[1:])) and 'K' in video[0]['flags']
stream=packet['streams'][0]
result={'source':'real screen from user-started GUI session','capture_backend':args.backend,'resolution':f"{stream['width']}x{stream['height']}",'stream_fps':stream['r_frame_rate'],'frames_per_segment':len(video),'monotonic_pts':True,'tv_states':[]}
with (ART/'real-avplayer.log').open('w') as log:
 native=subprocess.Popen([str(ROOT/'.build/debug/MacMirrorProbe'),'--play-url',hls,'--seconds','30'],stdout=log,stderr=subprocess.STDOUT)
for i in range(20):
 time.sleep(2);result['tv_states'].append({'seconds':2*(i+1),'state':state()})
 if i%5==0: print('REAL_TV_STATE',result['tv_states'][-1],flush=True)
assert native.wait(timeout=10)==0,'AVPlayer não confirmou reprodução contínua'
result['native_playback']=(ART/'real-avplayer.log').read_text().strip()
if args.interrupt:
 soap('Stop'); result['forced_stop']=state(); start=time.monotonic()
 for _ in range(25):
  time.sleep(2); s=state()
  if s=='PLAYING': result['reconnect_seconds']=round(time.monotonic()-start,2);break
 else: result['reconnect_failed']=True
 print('RECONNECT',result.get('reconnect_seconds','failed'),flush=True)
# A second independent HLS client joins the still live capture. Only sanitized decoder diagnostics are saved.
r=subprocess.run(['/opt/homebrew/bin/ffmpeg','-hide_banner','-loglevel','info','-i',hls,'-t','10','-f','null','-'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=35)
(ART/'real-http-decode.log').write_text(re.sub(r'/s/[a-f0-9]{16}/','/s/[redacted]/',r.stdout))
assert r.returncode==0
result['ffmpeg_http_decode']=True; result['final_tv_state']=state()
(ART/'real-summary.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
