import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('release_package',Path(__file__).with_name('package.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ReleaseGateTests(unittest.TestCase):
    def test_public_mode_fails_before_build_when_signing_inputs_are_absent(self):
        with patch.object(module,'output') as external:
            with self.assertRaisesRegex(RuntimeError,'BLOCKED'):
                module.preflight('release',None,None)
            external.assert_not_called()

    def test_apple_development_certificate_cannot_pass_as_public_signing(self):
        with patch.object(module,'output',return_value='1) ABC "Apple Development: Example"'):
            with self.assertRaisesRegex(RuntimeError,'Developer ID Application'):
                module.preflight('release','ABC','existing-profile')

    def test_notary_failure_is_not_a_success_and_receipt_survives_stage_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            fake=type('Reply',(),{'stdout':json.dumps({'status':'Invalid','id':'synthetic-submission'}),'stderr':'','returncode':0})()
            with patch.object(module,'ROOT',root),patch.object(module.subprocess,'run',return_value=fake):
                stage=root/'temp-stage';stage.mkdir()
                with self.assertRaisesRegex(RuntimeError,'Notarization not Accepted'):
                    module.notarize(root/'synthetic.zip','existing-profile',stage/'notary-app.json')
                self.assertEqual(len(list((root/'artifacts/release-failures').glob('*.json'))),1)

if __name__=='__main__':unittest.main()
