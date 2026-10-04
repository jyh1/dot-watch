import asyncio,json,pathlib,sys, fractions, time
import numpy as np
from aiortc import RTCPeerConnection, RTCSessionDescription, RTCConfiguration, MediaStreamTrack
from av import AudioFrame
D=pathlib.Path(sys.argv[1]); duration=int(sys.argv[2]) if len(sys.argv)>2 else 15; mode=sys.argv[3] if len(sys.argv)>3 else "normal"
class Tone(MediaStreamTrack):
 kind='audio'
 def __init__(self): super().__init__(); self.pts=0
 async def recv(self):
  await asyncio.sleep(.02)
  samples=(np.sin(np.arange(self.pts,self.pts+960)*2*np.pi*440/48000)*4000).astype(np.int16)
  frame=AudioFrame.from_ndarray(samples.reshape(1,-1),format='s16',layout='mono')
  frame.sample_rate=48000; frame.time_base=fractions.Fraction(1,48000); frame.pts=self.pts; self.pts+=960
  return frame
async def main():
 pc=RTCPeerConnection(RTCConfiguration(iceServers=[])); pc.addTrack(Tone()); stats={'frames':0,'peak':0,'channel':False,'secondPeaks':{}}
 @pc.on('track')
 def track(t):
  async def consume():
   started=None
   try:
    while True:
     f=await t.recv()
     if started is None: started=time.monotonic()
     peak=int(np.abs(f.to_ndarray().astype(np.int32)).max())
     stats['frames']+=1; stats['peak']=max(stats['peak'],peak)
     second=str(int(time.monotonic()-started))
     stats['secondPeaks'][second]=max(stats['secondPeaks'].get(second,0),peak)
   except Exception:
    pass
  asyncio.create_task(consume())
 @pc.on('datachannel')
 def channel(c): stats['channel']=True
 while not (D/'offer.sdp').exists():
  if (D/'done').exists(): raise RuntimeError('App ended before offering a call')
  await asyncio.sleep(.1)
 await pc.setRemoteDescription(RTCSessionDescription(sdp=(D/'offer.sdp').read_text(),type='offer'))
 await pc.setLocalDescription(await pc.createAnswer())
 (D/'answer.sdp').write_text(pc.localDescription.sdp)
 started=time.monotonic(); disconnected=False
 for _ in range((duration+60)*10):
  if mode in ('disconnect', 'blackhole') and not disconnected and time.monotonic()-started>14:
   stats['disconnectAt']=time.monotonic()
   if mode == 'blackhole':
    # Drop real UDP input/output without a DTLS close alert or peer-end signal.
    for protocol in pc.sctp.transport.transport._connection._protocols:
     protocol.transport.pause_reading()
     protocol.transport.sendto = lambda *args, **kwargs: None
   else:
    await pc.close()
   disconnected=True
  if (D/'done').exists(): break
  await asyncio.sleep(.1)
 stats['state']=pc.connectionState
 stats['finishedAt']=time.monotonic()
 (D/'peer-result.json').write_text(json.dumps(stats))
 print(stats,flush=True)
 await pc.close()
asyncio.run(main())
