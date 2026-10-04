import json
from pathlib import Path
import tempfile
import unittest
from configure import configuration, generate

class ConfigurationTests(unittest.TestCase):
    def test_defaults_have_no_personal_identity(self):
        c=configuration()
        self.assertEqual(c['app_name'],'Dot')
        self.assertEqual(c['development_team'],'')
        self.assertEqual(c['default_agent_page'],'')
        self.assertIsNone(c['avatar'])
    def test_private_build_then_public_resets_metadata_and_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); local=root/'private.json'
            local.write_text(json.dumps(dict(app_name='Example Agent',bundle_id='org.example.agent',url_scheme='exampleagent',widget_kind='ExistingWidget',siri_aliases=['Dot'],default_agent_page='00000000-0000-0000-0000-000000000001')))
            generate(configuration(local),root/'Generated')
            targets=json.loads((root/'Generated/Settings.yml').read_text())['targets']
            for key in ('DotWatchPhone','DotWatchWatch','DotWidget'):
                props=targets[key]['info']['properties']
                self.assertEqual(props['DotKeychainService'],'org.example.agent.account')
                self.assertEqual(props['DotURLScheme'],'exampleagent')
                self.assertEqual(props['DotWidgetKind'],'ExistingWidget')
            self.assertEqual(targets['DotWatchWatch']['info']['properties']['WKCompanionAppBundleIdentifier'],'org.example.agent')
            generate(configuration(),root/'Generated')
            self.assertNotIn('Example Agent',(root/'Generated/Settings.yml').read_text())
            self.assertEqual((root/'Generated/Widget/Dot.png').read_bytes(),(root/'Generated/Assets.xcassets/Dot.imageset/Dot.png').read_bytes())
    def test_unknown_secret_fields_and_malformed_values_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'config.json'
            for value in [dict(token='synthetic'),dict(url_scheme='HTTPS://'),dict(accent_hex='zzzzzz'),dict(bundle_id='not a bundle'),dict(signing='manual'),dict(siri_aliases='Dot')]:
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError): configuration(path)
    def test_relative_artwork_paths_resolve_beside_config(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'config.json'; image=Path(temp)/'avatar.png'
            image.write_bytes(b'\x89PNG\r\n\x1a\n')
            path.write_text(json.dumps(dict(avatar='avatar.png')))
            self.assertEqual(configuration(path)['avatar'],str(image.resolve()))

if __name__=='__main__': unittest.main()
