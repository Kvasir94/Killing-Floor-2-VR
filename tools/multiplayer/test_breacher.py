"""Offline tests of the optional Breacher content contract used by packaging and acceptance builds."""
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import breacher
import package
from session import read_ini


class BreacherTests(unittest.TestCase):
    def setUp(self):
        self.experimental_gate = patch("stable_features.experimental_content_enabled", return_value=True)
        self.experimental_gate.start(); self.addCleanup(self.experimental_gate.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.args = SimpleNamespace(breacher=True, host=True, solo=False)
        self.release = {"breacher_protocol": 1}
        self.folder = self.root / "optional/breacher"
        self.folder.mkdir(parents=True)
        # Package-parser fixture only, never fed to the engine or called compiled content.
        data = b"\xc1\x83\x2a\x9e" + b"offline package parser fixture"
        (self.folder / "KF2Breacher.u").write_bytes(data)
        self.contract = {"protocol": 1, "sha256": hashlib.sha256(data).hexdigest().upper()}
        (self.folder / "manifest.json").write_text(json.dumps(self.contract))
        locale = self.folder / "Localization/INT/KF2Breacher.int"
        locale.parent.mkdir(parents=True)
        locale.write_text("[BreacherPerk]\nPerkName=Breacher\n")
        self.args.game_root = self.root / "game"
        stock = self.args.game_root / "KFGame/Localization/INT/KFGame.int"
        stock.parent.mkdir(parents=True)
        stock.write_text("[KFPerk_Support]\nPerkName=Support\nStockArray[0]=Preserved\n", encoding="utf-16")

    def test_disabled_does_not_need_or_expose_optional_content(self):
        args = SimpleNamespace(breacher=False)
        self.assertIsNone(breacher.prepare(args, self.root / "absent", {}))
        self.assertEqual(breacher.options(args), "")
        self.assertEqual(breacher.add_mutator("KF-Outpost?Mutator=Existing.Mod", args), "KF-Outpost?Mutator=Existing.Mod")
        breacher.configure_content(self.root / "absent", args)

    def test_compiled_core_package_and_hash_are_required(self):
        with self.assertRaisesRegex(RuntimeError, "experimental core"):
            breacher.prepare(self.args, self.root, {})
        self.assertEqual(breacher.prepare(self.args, self.root, self.release), self.contract)
        (self.folder / "KF2Breacher.u").write_bytes(b"\xc1\x83\x2a\x9e" + b"changed")
        with self.assertRaisesRegex(RuntimeError, "hash differs"):
            breacher.prepare(self.args, self.root, self.release)
        (self.folder / "KF2Breacher.u").unlink()
        with self.assertRaisesRegex(RuntimeError, "missing"):
            breacher.prepare(self.args, self.root, self.release)

    def test_join_requires_matching_host_contract(self):
        self.args.host = False
        with self.assertRaisesRegex(RuntimeError, "complete join code"):
            breacher.prepare(self.args, self.root, self.release)
        self.args.breacher_expected = dict(self.contract, sha256="0" * 64)
        with self.assertRaisesRegex(RuntimeError, "differs from the host"):
            breacher.prepare(self.args, self.root, self.release)
        self.args.breacher_expected = self.contract
        self.assertEqual(breacher.prepare(self.args, self.root, self.release), self.contract)

    def test_single_mutator_option(self):
        breacher.prepare(self.args, self.root, self.release)
        for base in ("KF-Outpost?Game=Any", "KF-Outpost?Mutator=UnofficialKFPatch.UKFPMutator"):
            url = breacher.add_mutator(base, self.args) + breacher.options(self.args)
            self.assertEqual(url.count("?Mutator="), 1)
            self.assertEqual(url.count(breacher.MUTATOR), 1)
            self.assertIn("?BreacherProtocol=1?BreacherPackage=" + self.contract["sha256"], url)
            self.assertEqual(breacher.add_mutator(url, self.args), url)
        with self.assertRaises(ValueError):
            breacher.add_mutator("KF-Outpost?Mutator=A?mutator=B", self.args)

    def test_development_perk_level_mutator_config(self):
        configs = self.root / "configs"
        configs.mkdir()
        path = configs / "KFGame.ini"
        path.write_text("[Engine.GameInfo]\nValue=preserved\n", encoding="utf-16")
        breacher.configure_dev_level(configs, SimpleNamespace(breacher=True, breacher_level=25, breacher_skills="12121"))
        text = path.read_text(encoding="utf-16")
        self.assertIn("[KF2Breacher.BreacherMutator]", text)
        self.assertIn("DevPerkLevel=25", text)
        self.assertIn("DevSkills=12121", text)
        self.assertIn("Value=preserved", text)
        breacher.configure_dev_level(configs, SimpleNamespace(breacher=True, breacher_level=None, breacher_skills=None))
        text = path.read_text(encoding="utf-16")
        self.assertIn("DevPerkLevel=0", text)
        self.assertNotIn("DevPerkLevel=25", text)
        breacher.configure_dev_level(configs, SimpleNamespace(breacher=False, breacher_level=25, breacher_skills="12121"))
        self.assertIn("DevPerkLevel=0", path.read_text(encoding="utf-16"))

    def test_role_content_paths_are_idempotent_and_leave_existing_content(self):
        breacher.prepare(self.args, self.root, self.release)
        configs = self.root / "configs"
        configs.mkdir()
        path = configs / "KFEngine.ini"
        path.write_text("[Core.System]\nPaths=stock\nScriptPaths=stock\n[Other]\nValue=preserved\n", encoding="utf-16")
        breacher.configure_content(configs, self.args)
        first = path.read_bytes()
        breacher.configure_content(configs, self.args)
        self.assertEqual(first, path.read_bytes())
        text = path.read_text(encoding="utf-16")
        self.assertIn("Paths=stock", text)
        self.assertIn("Value=preserved", text)
        self.assertEqual(text.count(str(self.folder.resolve())), 5)
        self.args.breacher = False
        breacher.configure_content(configs, self.args)
        disabled = path.read_text(encoding="utf-16")
        self.assertNotIn(str(self.folder.resolve()), disabled)
        self.assertIn("Paths=stock", disabled)
        self.assertIn("Value=preserved", disabled)
        self.assertNotIn("KF2VRBreacherLocalization", disabled)

    def test_native_localization_preserves_stock_and_uses_authored_keys_in_both_languages(self):
        breacher.prepare(self.args, self.root, self.release)
        locale = self.folder / "Localization/INT/KF2Breacher.int"
        locale.write_text('[BreacherPerk]\nPerkName=Breacher\nTempering=Tempering\n'
                          'TemperingDescription=Stronger rods.\nSkillCatagories[0]=Weapons\n'
                          'Passives[0]=(Title="Damage",Description="Breacher damage")\n')
        stock = self.args.game_root / "KFGame/Localization"
        french = stock / "FRA/KFGame.fra"
        french.parent.mkdir()
        french.write_text('[KFPerk_Support]\nPerkName=Soutien amélioré\n[BreacherPerk]\n'
                          'PerkName=Stale\n', encoding="utf-16")
        originals = {p: p.read_bytes() for p in stock.rglob('*') if p.is_file()}
        configs = self.root / 'localized'
        configs.mkdir()
        engine = configs / 'KFEngine.ini'
        engine.write_text('[Engine.Engine]\nLanguage=FRA\n[Core.System]\n'
                          'LocalizationPaths=stock-locale\n', encoding="utf-16")
        breacher.configure_content(configs, self.args)
        generated = configs / 'KF2VRBreacherLocalization'
        for code in ('INT', 'FRA'):
            text = read_ini(generated / code / ('KFGame.' + code.lower()))
            self.assertEqual(text.count('[BreacherPerk]'), 1)
            self.assertIn('TemperingDescription=Stronger rods.', text)
            self.assertIn('SkillCatagories[0]=Weapons', text)
            self.assertIn('Passives[0]=(Title="Damage",Description="Breacher damage")', text)
        self.assertIn('PerkName=Soutien amélioré', read_ini(generated / 'FRA/KFGame.fra'))
        self.assertIn('StockArray[0]=Preserved', read_ini(generated / 'INT/KFGame.int'))
        paths = [line.partition('=')[2] for line in read_ini(engine).splitlines()
                 if line.startswith('LocalizationPaths=')]
        self.assertEqual(paths[0], str(generated.resolve()))
        self.assertEqual(paths[-1], 'stock-locale')
        self.assertEqual(originals, {p: p.read_bytes() for p in originals})

    def test_native_localization_missing_language_uses_int_and_missing_stock_fails(self):
        breacher.prepare(self.args, self.root, self.release)
        configs = self.root / 'localized'
        folder = breacher.native_localization(configs, self.args.breacher_content,
                                               '[Engine.Engine]\nLanguage=DEU\n', self.args.game_root)
        self.assertTrue((folder / 'INT/KFGame.int').is_file())
        self.assertFalse((folder / 'DEU/KFGame.deu').exists())
        with self.assertRaisesRegex(RuntimeError, 'installed KFGame'):
            breacher.native_localization(configs, self.args.breacher_content, '', self.root / 'missing')

    def test_optional_packaging_rejects_stale_script_sources(self):
        import shutil
        built = self.root / "build/breacher"
        built.mkdir(parents=True)
        for name in ("KF2Breacher.u", "manifest.json"):
            shutil.copy2(self.folder / name, built / name)
        shutil.copytree(self.folder / "Localization", built / "Localization")
        sources = self.root / "script/KF2Breacher/Classes"
        sources.mkdir(parents=True)
        source = sources / "Example.uc"
        source.write_text("class Example extends Object;")
        shutil.copytree(self.folder / "Localization", sources.parent / "Localization")
        record = {"success": True, "package_sha256": self.contract["sha256"],
                  "localization_sha256": package.digest(built / "Localization/INT/KF2Breacher.int"),
                  "sources_sha256": {"Classes/Example.uc": package.digest(source)}}
        (built / "build.json").write_text(json.dumps(record))
        output = self.root / "release"
        package.copy_breacher_package(self.root, output)
        self.assertEqual((output / "optional/breacher/KF2Breacher.u").read_bytes(), (built / "KF2Breacher.u").read_bytes())
        source.write_text("class Changed extends Object;")
        with self.assertRaisesRegex(RuntimeError, "Compile current Breacher"):
            package.copy_breacher_package(self.root, self.root / "stale")



if __name__ == "__main__":
    unittest.main()
