"""Installed map discovery and config mounting; no downloads or game launch."""
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from installed_map_catalog import catalog
from launch_menu import installed_solo_maps, installed_maps
from workshop_loadout import prepare_content, configure_content
from session import read_ini


class InstalledMapsTests(unittest.TestCase):
    def test_host_can_mount_client_only_brewed_map_without_shadowing_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            game = root/'game'
            maps = game/'KFGame/BrewedPC/Maps/Custom'
            maps.mkdir(parents=True)
            (maps/'KF-Local.kfm').write_bytes(b'\xc1\x83\x2a\x9e')
            server = root/'server'
            (server/'Binaries/Win64').mkdir(parents=True)
            (server/'Binaries/Win64/KFServer.exe').touch()
            args = SimpleNamespace(map='KF-Local', mods=[], cache_root=root/'cache', prepare_only=True)
            with patch('installed_map_catalog.user_game_root', return_value=root/'user'):
                self.assertIn('KF-Local', installed_maps(game, server))
                prepare_content(args, game, root/'steamcmd')
            config = root/'config'
            config.mkdir()
            (config/'KFEngine.ini').write_text('[Core.System]\nPaths=selected-release\n')
            configure_content(config, args, server=True)
            text = read_ini(config/'KFEngine.ini')
            self.assertLess(text.index('Paths=selected-release'), text.index('Paths=' + str(maps)))

    def test_workshop_map_and_companion_packages_mount_in_both_roles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            game = root / 'steamapps/common/killingfloor2'
            game.mkdir(parents=True)
            content = root / 'steamapps/workshop/content/232090/12345'
            maps = content / 'BrewedPC/Maps'
            textures = content / 'BrewedPC/Packages'
            maps.mkdir(parents=True)
            textures.mkdir()
            payload = b'\xc1\x83\x2a\x9e' + b'package fixture'
            (maps / 'KF-Custom.kfm').write_bytes(payload)
            (textures / 'CustomTextures.upk').write_bytes(payload)
            args = SimpleNamespace(map='KF-Custom', mods=[], cache_root=root/'cache', prepare_only=True)
            with patch('installed_map_catalog.user_game_root', return_value=root/'user'):
                self.assertIn('KF-Custom', installed_solo_maps(game))
                prepare_content(args, game, root/'steamcmd')
            for server in (False, True):
                config = root / str(server)
                config.mkdir()
                (config/'KFEngine.ini').write_text('[Core.System]\nPaths=stock\n')
                configure_content(config, args, server=server)
                text = read_ini(config/'KFEngine.ini')
                self.assertIn('Paths=' + str(maps), text)
                self.assertIn('Paths=' + str(textures), text)
                self.assertEqual(server, 'ServerSubscribedWorkshopItems=12345' in text)
            self.assertFalse((root/'cache').exists())
            self.assertEqual(payload, (maps/'KF-Custom.kfm').read_bytes())

    def test_stock_wins_duplicate_names_and_redirected_user_cache_is_discovered(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            game = root/'game'
            stock = game/'KFGame/BrewedPC/Maps'
            custom = root/'redirected/Cache/777/BrewedPC'
            stock.mkdir(parents=True)
            custom.mkdir(parents=True)
            (stock/'KF-Outpost.kfm').touch()
            (custom/'kf-outpost.KFM').touch()
            (custom/'KF-User.kfm').touch()
            with patch('installed_map_catalog.user_game_root', return_value=root/'redirected'):
                found = catalog(game)
            self.assertEqual({'KF-Outpost', 'KF-User'}, set(found))
            self.assertEqual((game/'KFGame/BrewedPC', ''), found['KF-Outpost'])
            self.assertEqual('777', found['KF-User'][1])
