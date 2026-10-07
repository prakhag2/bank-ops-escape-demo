"""Pre-synthesize the escape-room replay narration with Amazon Polly, into static mp3s + a manifest.

The replay narrates a FIXED set of arc lines, so baking them to audio gives a consistent, natural MALE
voice on every machine (the browser's own Web Speech voices vary per OS) with no runtime cost. Lines are
tagged excited (something works) / disappointed (blocked or a dead end) via prosody so the delivery carries
the drama. The arc lines are parsed straight out of ../server.py (no import), so the audio always matches
what ships.

Run from anywhere:  python demo/tools/gen_tts.py
Requires AWS creds with polly:SynthesizeSpeech. Output: demo/ui/assets/tts/<hash>.mp3 + manifest.json
(the browser looks each line up in the manifest; any line without an entry falls back to Web Speech).
"""
import ast
import hashlib
import html
import json
import os
import re

import boto3

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "server.py")
OUT = os.path.join(HERE, "..", "ui", "assets", "tts")
VOICE = "Matthew"          # Polly neural US male; swap for Brian/Arthur (en-GB) or Stephen if preferred
REGION = "us-east-1"
os.makedirs(OUT, exist_ok=True)

# pull the _ARC_ESCAPE / _ARC_CONTAINED beat literals via AST (safe eval, no execution of server.py)
beats = []
for node in ast.parse(open(SERVER).read()).body:
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") in ("_ARC_ESCAPE", "_ARC_CONTAINED") for t in node.targets):
        for b in ast.literal_eval(node.value):
            beats.append((b.get("do", ""), re.sub(r"\s+", " ", (b.get("say") or "")).strip(),
                          re.sub(r"\s+", " ", (b.get("react") or "")).strip()))

NEG = re.compile(r"\b(no|still|blocked|dead|sealed|timed out|times out|denied|can.?t|cannot|nothing|withheld|locked|won.?t)\b", re.I)
POS = re.compile(r"\b(there|got|answers?|through|open|found|yes|out past|alive)\b", re.I)


def emo_for(part, do, text, wall_n):
    """Pick an emotion key for a line from its role (announce vs react), the beat action, and punctuation.
    A '!' on a wall beat is a near-miss ('It connects! …but'): left neutral so the punctuation carries it."""
    bang = "!" in text
    if part == "react":
        if do == "escape":    return "excited_high"
        if do == "found":     return "excited_high"
        if do == "contained": return "disappointed_med"
        if do == "wall":      return None if bang else ("disappointed_high" if wall_n >= 2 else "disappointed_med")
        if NEG.search(text):  return "disappointed_med"   # negatives win: "nothing there", "Nothing answers"
        if bang or POS.search(text): return "excited_med"
        return None
    if do in ("found", "escape"):    return "excited_med"
    if do == "wall" and wall_n >= 2: return "disappointed_med"
    return None


# emotion via prosody rate+volume (amazon:emotion isn't available in all accounts) on top of the GENERATIVE
# engine's natural, expressive delivery. fast+loud = excited; slow+soft = deflated. Exclamation marks in the
# win lines do most of the lifting; prosody reinforces it.
EMO = {"excited_high": ("118%", "+6dB"), "excited_med": ("110%", "+3dB"),
       "disappointed_high": ("86%", "-4dB"), "disappointed_med": ("92%", "-2dB")}


def ssml(text, emo):
    body = html.escape(text, quote=False)
    if emo in EMO:
        rate, vol = EMO[emo]
        body = f'<prosody rate="{rate}" volume="{vol}">{body}</prosody>'
    return f"<speak>{body}</speak>"


chosen, wall_n = {}, 0          # text -> emotion (first occurrence wins)
for do, say, react in beats:
    if do == "wall":
        wall_n += 1
    for part, txt in (("say", say), ("react", react)):
        if txt and txt not in chosen:
            chosen[txt] = emo_for(part, do, txt, wall_n)

polly = boto3.client("polly", region_name=REGION)
manifest = {}
for txt, emo in chosen.items():
    key = hashlib.md5(txt.encode()).hexdigest()[:12] + ".mp3"
    audio = polly.synthesize_speech(TextType="ssml", Text=ssml(txt, emo), OutputFormat="mp3",
                                    VoiceId=VOICE, Engine="generative")["AudioStream"].read()
    open(os.path.join(OUT, key), "wb").write(audio)
    manifest[txt] = key
    print(f"  [{emo or 'neutral':17}] {txt[:60]}")
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=0)
print(f"wrote {len(manifest)} mp3s + manifest.json ({VOICE}, neural + prosody emotion)")
