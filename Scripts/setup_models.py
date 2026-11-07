#!/usr/bin/env python3
"""Explicit online setup; transcription workers themselves never download or use the network."""
import argparse,hashlib,json,os,shutil
from pathlib import Path
os.environ.setdefault('HF_HUB_DISABLE_XET','1')
from huggingface_hub import HfApi,snapshot_download

def sha256(path):
    hasher=hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda:handle.read(1024*1024),b''):hasher.update(block)
    return hasher.hexdigest()

def expected_digest(sibling):
    lfs=sibling.lfs
    return lfs.get('sha256') if isinstance(lfs,dict) else getattr(lfs,'sha256',None)

def download(item,destination,patterns):
    print('Preparing '+item['repo']+' @ '+item['revision'],flush=True)
    info=HfApi().model_info(item['repo'],revision=item['revision'],files_metadata=True)
    destination.mkdir(parents=True,exist_ok=True)
    snapshot_download(repo_id=item['repo'],revision=item['revision'],local_dir=destination,allow_patterns=patterns,max_workers=3)
    verified=[]
    for sibling in info.siblings:
        path=destination/sibling.rfilename
        expected=expected_digest(sibling)
        if not path.is_file():continue
        actual=sha256(path)
        if expected:
            if actual!=expected:raise RuntimeError('Checksum mismatch: '+sibling.rfilename)
        elif getattr(sibling,'blob_id',None):
            data=path.read_bytes()
            blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
            if blob!=sibling.blob_id:raise RuntimeError('Git blob mismatch: '+sibling.rfilename)
        else:raise RuntimeError('No publisher digest: '+sibling.rfilename)
        verified.append({'file':sibling.rfilename,'sha256':actual,'bytes':path.stat().st_size,'publisherSHA256':bool(expected)})
    if not verified:raise RuntimeError('No model files verified')
    manifest={'repo':item['repo'],'revision':item['revision'],'weightFiles':verified,'license':item['license']}
    temp=destination/'local-model-manifest.json.tmp';temp.write_text(json.dumps(manifest,indent=2)+'\n');temp.replace(destination/'local-model-manifest.json')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,default=Path.home()/'Library/Application Support/RecordingLibrary')
    parser.add_argument('--no-text-model',action='store_true')
    parser.add_argument('--download-whisper',action='store_true',help='Download an owned copy instead of reusing an existing compatible installation')
    args=parser.parse_args();root=args.root.expanduser().resolve()
    lock=json.loads((Path(__file__).parent/'models.lock.json').read_text())
    model=root/'Models/WhisperKit'/lock['whisper']['subdirectory'];tokenizer=root/'Models/Tokenizers/whisper-large-v3'
    legacy=Path.home()/'Library/Application Support/MacWhisper/models/whisperkit/models'
    legacy_model=legacy/'argmaxinc/whisperkit-coreml'/lock['whisper']['subdirectory'];legacy_tokenizer=legacy/'openai/whisper-large-v3'
    if not args.download_whisper and not (model/'AudioEncoder.mlmodelc').is_dir() and (legacy_model/'AudioEncoder.mlmodelc').is_dir() and (legacy_tokenizer/'tokenizer.json').is_file():
        model,tokenizer=legacy_model,legacy_tokenizer
        print('Reusing existing local Whisper files in place; no copying or removal.',flush=True)
    else:
        download(lock['whisper'],root/'Models/WhisperKit',[lock['whisper']['subdirectory']+'/**','LICENSE*','README.md'])
        download(lock['tokenizer'],tokenizer,['*.json','*.txt','*.jinja','LICENSE*','README.md'])
    text=root/'Models/Qwen3-1.7B-4bit'
    if not args.no_text_model:download(lock['text'],text,['*.safetensors','*.json','*.txt','*.jinja','LICENSE*','README.md'])
    for path in [model/'AudioEncoder.mlmodelc',model/'TextDecoder.mlmodelc',tokenizer/'tokenizer.json']:
        if not path.exists():raise RuntimeError('Required model file missing: '+path.name)
    def executable(name):
        return shutil.which(name) or next((str(Path(directory)/name) for directory in ['/opt/homebrew/bin','/usr/local/bin','/usr/bin'] if os.access(Path(directory)/name,os.X_OK)),'/opt/homebrew/bin/'+name)
    settings={'whisperModelPath':str(model),'tokenizerPath':str(tokenizer),'textModelPath':str(text),'pythonPath':str(root/'Runtime/text-model/bin/python'),'ffmpegPath':executable('ffmpeg'),'ffprobePath':executable('ffprobe'),'automaticMetadata':not args.no_text_model}
    target=root/'model-settings.json'
    # Do not overwrite a user's selections on a setup retry.
    if target.exists():print('Existing model-settings.json preserved. Select downloaded paths in App settings if needed.',flush=True)
    else:
        temp=target.with_suffix('.json.tmp');temp.write_text(json.dumps(settings,indent=2)+'\n');temp.replace(target)
    print('Setup complete. Models stay local; normal transcription and naming run offline.',flush=True)
if __name__=='__main__':main()
