#!/usr/bin/env python3
"""Observe live HLS and DLNA without saving real video or access tokens."""
import argparse,json,pathlib,re,subprocess,time,urllib.request,xml.etree.ElementTree as E
ROOT=pathlib.Path(__file__).resolve().parents[1]; ART=ROOT/'artifacts'
p=argparse.ArgumentParser();p.add_argument('--seconds',type=int,default=360);p.add_argument('--tv',default='192.168.0.13');p.add_argument('--backend',default='unknown (check GUI)');args=p.parse_args()
ns='urn:schemas-upnp-org:service:AVTransport:1'
def call(action):
 body='<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:'+action+' xmlns:u="'+ns+'"><InstanceID>0</InstanceID></u:'+action+'></s:Body></s:Envelope>'
 r=urllib.request.Request('http://'+args.tv+':9197/upnp/control/AVTransport1',data=body.encode(),headers={'Content-Type':'text/xml; charset="utf-8"','SOAPAction':'"'+ns+'#'+action+'"'})
 return E.fromstring(urllib.request.urlopen(r,timeout=5).read())
def field(root,name):return next((n.text for n in root.iter() if n.tag.split('}')[-1]==name),'')
uri=field(call('GetMediaInfo'),'CurrentURI'); assert re.match(r'^http://[0-9.]+:8787/s/[a-f0-9]{16}/live\.',uri)
hls=uri.rsplit('/',1)[0]+'/live.m3u8'
rows=subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines()
app=[int(x.strip().split(None,1)[0]) for x in rows if x.strip().split(None,1)[1].startswith(str(ROOT/'dist/MacMirror.app/Contents/MacOS/MacMirror'))]
assert len(app)==1; pid=app[0]
start=time.monotonic(); observations=[]; rss=[]; sequences=[]
summary={'backend':args.backend,'requested_seconds':args.seconds,'observations':observations}
for elapsed in range(0,args.seconds+1,10):
 if elapsed: time.sleep(max(0,start+elapsed-time.monotonic()))
 playlist=urllib.request.urlopen(hls,timeout=5).read().decode()
 sequence=int(re.search(r'#EXT-X-MEDIA-SEQUENCE:(\d+)',playlist)[1]);sequences.append(sequence)
 memory=int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)],text=True).strip());rss.append(memory)
 state=field(call('GetTransportInfo'),'CurrentTransportState')
 assert '#EXT-X-ENDLIST' not in playlist and len([x for x in playlist.splitlines() if x.endswith('.ts')])<=6
 if len(sequences)>1: assert sequence>sequences[-2], 'Playlist deixou de avançar'
 observations.append({'seconds':elapsed,'sequence':sequence,'tv_state':state,'rss_kib':memory})
 (ART/'compatibility-watch-progress.json').write_text(json.dumps(summary,indent=2))
 if elapsed%60==0: print('LIVE',observations[-1],flush=True)
# Verify actual decoded picture changes, retaining only an aggregate count of frame hashes.
result=subprocess.run(['/opt/homebrew/bin/ffmpeg','-hide_banner','-loglevel','error','-i',hls,'-t','8','-an','-f','framemd5','-'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=30)
assert result.returncode==0
hashes=[line.rsplit(',',1)[-1].strip() for line in result.stdout.splitlines() if line and not line.startswith('#')]
summary.update({'elapsed_seconds':round(time.monotonic()-start,2),'rss_kib_min':min(rss),'rss_kib_max':max(rss),'sequence_first':sequences[0],'sequence_last':sequences[-1],'decoded_frames':len(hashes),'distinct_decoded_pictures':len(set(hashes)),'http_continuous':True})
(ART/'compatibility-watch-summary.json').write_text(json.dumps(summary,indent=2));print('PASS',json.dumps({k:v for k,v in summary.items() if k!='observations'}),flush=True)
