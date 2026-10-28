#!/usr/bin/env python3
"""Inspect a user-started DLNA session; retain metadata only, never real PCM/pixels/tokens."""
import argparse
import array
import json
import math
import pathlib
import subprocess
import urllib.request
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tv', default='192.168.0.13')
    args = parser.parse_args()
    namespace = 'urn:schemas-upnp-org:service:AVTransport:1'
    body = ('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body><u:GetMediaInfo xmlns:u="' + namespace + '">'
            '<InstanceID>0</InstanceID></u:GetMediaInfo></s:Body></s:Envelope>')
    request = urllib.request.Request(
        'http://' + args.tv + ':9197/upnp/control/AVTransport1', data=body.encode(),
        headers={'Content-Type': 'text/xml', 'SOAPAction': '"' + namespace + '#GetMediaInfo"'})
    tree = ET.fromstring(urllib.request.urlopen(request, timeout=5).read())
    uri = next(element.text for element in tree.iter() if element.tag.split('}')[-1] == 'CurrentURI')
    # All access remains on the user's LAN; do not follow a receiver's arbitrary external URL.
    import ipaddress
    from urllib.parse import urlparse
    parsed = urlparse(uri)
    assert parsed.scheme == 'http' and ipaddress.ip_address(parsed.hostname).is_private
    assert '/s/' in parsed.path and parsed.path.endswith(('/live.ts', '/live.m3u8'))
    base = uri.rsplit('/', 1)[0]
    status = json.load(urllib.request.urlopen(base + '/status', timeout=5))
    playlist = urllib.request.urlopen(base + '/live.m3u8', timeout=5).read().decode()
    import re
    names = [name for name in playlist.splitlines() if re.fullmatch(r'seg[0-9]+\.ts', name)]
    assert names, 'Nenhum segmento completo disponível'
    segment = urllib.request.urlopen(base + '/' + names[-1], timeout=5).read()
    ffmpeg = next(path for path in ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'] if pathlib.Path(path).is_file())
    probe = str(pathlib.Path(ffmpeg).with_name('ffprobe'))
    metadata = json.loads(subprocess.check_output(
        [probe, '-v', 'error', '-show_streams', '-show_packets', '-of', 'json', 'pipe:0'],
        input=segment, stderr=subprocess.DEVNULL, timeout=10))
    audio = next(stream for stream in metadata['streams'] if stream['codec_type'] == 'audio')
    pcm = subprocess.check_output(
        [ffmpeg, '-v', 'error', '-i', 'pipe:0', '-map', '0:a:0', '-f', 'f32le', 'pipe:1'],
        input=segment, stderr=subprocess.DEVNULL, timeout=10)
    samples = array.array('f'); samples.frombytes(pcm)
    energy = sum(float(value) ** 2 for value in samples) / max(1, len(samples))
    result = {
        'source': 'user-started GUI; metadata and levels only',
        'status': status,
        'audio_codec': audio['codec_name'], 'sample_rate': audio['sample_rate'], 'channels': audio['channels'],
        'decoded_audio_dbfs': round(10 * math.log10(max(1e-12, energy)), 2),
        'physical_tv_sound': 'requires user confirmation',
        'end_to_end_latency': 'not measured',
    }
    packets = metadata['packets']
    video_pts = [float(packet['pts_time']) for packet in packets if packet['codec_type'] == 'video']
    audio_pts = [float(packet['pts_time']) for packet in packets if packet['codec_type'] == 'audio']
    result['av_start_difference_ms'] = round(abs(video_pts[0] - audio_pts[0]) * 1000, 2)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Exceptions from networking/FFmpeg can contain the live token; show only their type.
        raise SystemExit('Diagnóstico indisponível: ' + type(error).__name__ + '. Confira a sessão e a TV.')
