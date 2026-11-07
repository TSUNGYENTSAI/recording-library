"""Offline setup verification: a corrupt download cannot produce a verified manifest."""
import hashlib,importlib.util,json,sys,tempfile,types,unittest
from pathlib import Path
from unittest.mock import patch
hub=types.ModuleType('huggingface_hub');hub.HfApi=lambda:None;hub.snapshot_download=lambda **kwargs:None
with patch.dict(sys.modules,{'huggingface_hub':hub}):
 spec=importlib.util.spec_from_file_location('setup_models',Path(__file__).resolve().parents[1]/'Scripts/setup_models.py')
 setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)

class SetupChecks(unittest.TestCase):
 def run_download(self,payload,expected,root):
  sibling=types.SimpleNamespace(rfilename='weights.safetensors',lfs={'sha256':expected})
  api=types.SimpleNamespace(model_info=lambda *args,**kwargs:types.SimpleNamespace(siblings=[sibling]))
  def snapshot(**kwargs):(kwargs['local_dir']/'weights.safetensors').write_bytes(payload)
  with patch.object(setup,'HfApi',return_value=api),patch.object(setup,'snapshot_download',side_effect=snapshot):
   setup.download({'repo':'synthetic/model','revision':'fixed-test-revision','license':'MIT'},root,['*.safetensors'])
 def test_verified_download_records_revision(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);payload=b'synthetic public fixture'
   self.run_download(payload,hashlib.sha256(payload).hexdigest(),root)
   self.assertEqual(json.loads((root/'local-model-manifest.json').read_text())['revision'],'fixed-test-revision')
 def test_corrupt_download_has_no_success_manifest(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory)
   with self.assertRaisesRegex(RuntimeError,'Checksum mismatch'):self.run_download(b'corrupt','0'*64,root)
   self.assertFalse((root/'local-model-manifest.json').exists())
if __name__=='__main__':unittest.main()
