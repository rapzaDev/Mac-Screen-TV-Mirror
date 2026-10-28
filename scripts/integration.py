#!/usr/bin/env python3
"""Live integration with SYNTHETIC frames only. Does not grant capture permission. Only contacts the TV when --tv is passed."""
import argparse, json, pathlib, re, subprocess, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
ART=ROOT/'artifacts'; ART.mkdir(exist_ok=True)
FF='/opt/homebrew/bin/ffmpeg'; FP='/opt/homebrew/bin/ffprobe'
probe=ROOT/'.build/debug/MacMirrorProbe'
subprocess.run(['swift','build'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
parser=argparse.ArgumentParser(); parser.add_argument("--tv"); args=parser.parse_args()
log=(ART/'soak.log').open('w')
producer=subprocess.Popen([str(probe),'--seconds','120','--token','0123456789abcdef'] + (['--tv',args.tv] if args.tv else []),cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
summary={}; playlist_url=None; directory=None
try:
    deadline=time.time()+25
    while time.time()<deadline:
        line=producer.stdout.readline(); log.write(line); log.flush()
        if line.startswith('HLS '): playlist_url=line.strip()[4:]
        if line.startswith('TEMP '): directory=pathlib.Path(line.strip()[5:]); break
        if producer.poll() is not None: raise RuntimeError('Produtor falhou antes de READY')
    assert playlist_url and directory
    summary['source']='synthetic animated color bars'; summary['quality']='1280x720@30'
    playback_log=(ART/'soak-avplayer.log').open('w')
    player=subprocess.Popen([str(probe),'--play-url',playlist_url,'--seconds','25'],cwd=ROOT,stdout=playback_log,stderr=subprocess.STDOUT)
    # HTTP MPEG-TS decoder, in parallel with native HLS playback.
    ts_url=playlist_url.replace('live.m3u8','live.ts')
    ts_log=(ART/'soak-ts-decode.log').open('w')
    decoder=subprocess.Popen([FF,'-hide_banner','-loglevel','info','-i',ts_url,'-t','15','-f','null','-'],stdout=ts_log,stderr=subprocess.STDOUT)
    rss=[]; segment_counts=[]; sequences=[]; inspected=False
    for tick in range(110):
        time.sleep(1)
        if producer.poll() is not None: break
        memory=subprocess.check_output(['ps','-o','rss=','-p',str(producer.pid)],text=True).strip()
        if memory: rss.append(int(memory))
        segment_counts.append(len(list(directory.glob('*.ts'))))
        if tick % 5 == 0:
            text=urllib.request.urlopen(playlist_url,timeout=3).read().decode()
            sequences.append(int(re.search(r'#EXT-X-MEDIA-SEQUENCE:(\d+)',text)[1]))
            names=[n for n in text.splitlines() if n.endswith('.ts')]
            assert 1<=len(names)<=6 and '#EXT-X-ENDLIST' not in text
            if tick>15 and not inspected:
                segment=ART/'soak-segment.ts'; segment.write_bytes(urllib.request.urlopen(playlist_url.rsplit('/',1)[0]+'/'+names[-1],timeout=3).read())
                packet=json.loads(subprocess.check_output([FP,'-v','error','-show_packets','-show_streams','-of','json',str(segment)]))
                video=[p for p in packet['packets'] if p['codec_type']=='video']
                pts=[float(p['pts_time']) for p in video]
                assert len(video)==30 and all(b>a for a,b in zip(pts,pts[1:]))
                assert all(abs(b-a-1/30)<0.00002 for a,b in zip(pts,pts[1:]))
                assert 'K' in video[0]['flags']
                stream=packet['streams'][0]; assert stream['width']==1280 and stream['height']==720
                assert stream['r_frame_rate']=='30/1' and stream['sample_aspect_ratio']=='1:1'
                summary['segment_video_frames']=len(video); summary['monotonic_pts']=True; summary['frame_step_seconds']=1/30
                inspected=True
        if tick==35:
            # A fresh client joins after the first decoder has stopped.
            with (ART/'soak-hls-rejoin.log').open('w') as joined:
                subprocess.run([FF,'-hide_banner','-loglevel','info','-i',playlist_url,'-t','8','-f','null','-'],stdout=joined,stderr=subprocess.STDOUT,timeout=25,check=True)
    assert player.wait(timeout=10)==0, 'AVPlayer não reproduziu continuamente'
    assert decoder.wait(timeout=10)==0, 'Decoder TS falhou'
    summary['avplayer']= (ART/'soak-avplayer.log').read_text().strip()
    summary['rss_kib_min']=min(rss); summary['rss_kib_max']=max(rss)
    summary['max_ts_files']=max(segment_counts); assert max(segment_counts)<=10
    summary['playlist_sequence_first']=sequences[0]; summary['playlist_sequence_last']=sequences[-1]
    assert sequences[-1]>sequences[0]+40
    remainder=producer.communicate(timeout=25)[0]; log.write(remainder); log.flush()
    assert producer.returncode==0; assert not directory.exists()
    try: urllib.request.urlopen(playlist_url,timeout=2); raise AssertionError('Servidor continuou disponível após Stop')
    except OSError: pass
    summary['stop_removed_segments']=True; summary['stop_closed_http']=True
    (ART/'integration-summary.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary,indent=2))
finally:
    if producer.poll() is None:
        producer.terminate(); producer.wait(timeout=10)
    log.close()
