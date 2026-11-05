"""Screenshot request/file parser tests; fixture pixels are not game evidence."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

spec = importlib.util.spec_from_file_location('replay_captures_test_module', Path(__file__).with_name('captures.py'))
captures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(captures)

STAMP = '20261018124530000000'


def name(case=1, index=1):
    return f'KF2VR_Replay_{STAMP}_{case}_{index}'


def request(case=1, index=1, event='reload_held', seconds=12.5):
    return f'[0012.50] ScriptLog: KF2VR_REPLAY_CAPTURE caseIndex={case} index={index} name={name(case,index)} event={event} time={seconds}'


def bmp(bits=24, uniform=False, top_down=False):
    width, height = 3, 2
    stride = ((width*bits+31)//32)*4
    rows = bytearray()
    for y in range(height):
        row = bytearray()
        for x in range(width):
            pixel = (0, 0, 0) if uniform else (x*50, y*100, x*10+y*20)
            row.extend(pixel)
            if bits == 32:
                row.append(0)  # UE's 32-bit BMP alpha is not a usable image mask.
        rows.extend(row+b'\0'*(stride-len(row)))
    header = b'BM'+struct.pack('<IHHI', 54+len(rows), 0, 0, 54)
    header += struct.pack('<IiiHHIIiiII', 40, width, -height if top_down else height, 1, bits,
                          0, len(rows), 0, 0, 0, 0)
    return header+rows


def png(uniform=False, broken_filter=False):
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data))
    raw = b'\0\0\0\0'+(b'\0\0\0' if uniform else b'\x20\x30\x40')
    raw += (b'\x05' if broken_filter else b'\0')+b'\0'*6
    return (b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB',2,2,8,2,0,0,0))+
            chunk(b'IDAT', zlib.compress(raw))+chunk(b'IEND',b''))


class CaptureTests(unittest.TestCase):
    def setup_run(self, directory):
        run = Path(directory)
        source = run/'driver/ScreenShotPath'
        source.mkdir(parents=True)
        (source.parent/'game.log').write_text('fixture log')
        return run, source

    def write_image(self, source, index=1, data=None, modified=100, prefix='', case=1, suffix='0.bmp'):
        path = source/(prefix+name(case,index)+suffix)
        path.write_bytes(bmp() if data is None else data)
        os.utime(path, (modified, modified))
        return path

    def collect(self, run, text):
        return captures.collect_captures(run, text, started_unix=90, finished_unix=110)

    def test_older_shots_in_a_shared_folder_do_not_exhaust_the_bound(self):
        # The game's own Screenshots folder keeps thousands of older shots.
        with tempfile.TemporaryDirectory() as directory:
            run,source=self.setup_run(directory)
            for index in range(1,4200):
                self.write_image(source,index=index,data=b'x',modified=50,case=2)
            self.write_image(source)
            result=self.collect(run,request())
            self.assertTrue(result['passed'],result['errors'])
            self.assertTrue((source/(name(2,1)+'0.bmp')).exists())

    def test_parser_retains_real_log_line_and_game_time(self):
        entries, errors = captures.capture_requests('Other log\n'+request())
        self.assertEqual([], errors)
        self.assertEqual((2,12.5,1,1), tuple(entries[0][k] for k in
            ('log_line','requested_game_seconds','case_index','index')))

    def test_actual_observer_seven_field_marker_retains_deferred_event_time(self):
        text=request()+' eventTime=10.1250 deferred=True'
        entries,errors=captures.capture_requests(text)
        self.assertEqual([],errors)
        self.assertEqual(10.125,entries[0]['event_game_seconds'])
        self.assertEqual(12.5,entries[0]['requested_game_seconds'])
        self.assertTrue(entries[0]['deferred'])
        with tempfile.TemporaryDirectory() as directory:
            run,source=self.setup_run(directory)
            self.write_image(source)
            result=self.collect(run,text)
            self.assertTrue(result['passed'],result['errors'])
            page=Path(result['html']).read_text()
            self.assertIn('Event game time 10.125',page)
            self.assertIn('screenshot request 12.5',page)
            self.assertIn('deferred True',page)
        for tail in (' eventTime=13 deferred=True', ' eventTime=nan deferred=True',
                     ' eventTime=10 deferred=maybe', ' eventTime=10'):
            self.assertTrue(captures.capture_requests(request()+tail)[1])

    def test_bad_duplicate_and_unordered_requests_fail_closed(self):
        bad = [request()+' extra=value', request()+' index=1', request(index=2),
               request().replace('time=12.5','time=nan'), request(seconds=0),
               request().replace('event=reload_held','event=../other'), request(case=17),
               request().replace(name(), '../outside'), request()+'\n'+request()]
        for text in bad:
            with self.subTest(text=text):
                self.assertTrue(captures.capture_requests(text)[1])
        text = '\n'.join(request(case=c, index=i) for c in range(1,10) for i in range(1,17))
        entries, errors = captures.capture_requests(text)
        self.assertEqual(128, len(entries))
        self.assertTrue(errors)

    def test_bmp_24_and_32_bit_odd_stride_and_top_down_pixels(self):
        for bits in (24,32):
            for top_down in (False,True):
                with self.subTest(bits=bits, top_down=top_down), tempfile.TemporaryDirectory() as directory:
                    run, source = self.setup_run(directory)
                    original = self.write_image(source, data=bmp(bits=bits,top_down=top_down),
                                                prefix='KF-OUTPOST-PC-18-12.45.30')
                    before = original.read_bytes()
                    result = self.collect(run, request())
                    self.assertTrue(result['passed'], result['errors'])
                    entry = result['entries'][0]
                    self.assertEqual(before, original.read_bytes())
                    self.assertEqual(hashlib.sha256(before).hexdigest().upper(), entry['source_sha256'])
                    self.assertEqual((3,2), (entry['width'],entry['height']))
                    self.assertTrue(Path(entry['image_path']).is_absolute())
                    self.assertEqual('1970-01-01T00:01:40+00:00',entry['file_written_utc'])
                    self.assertTrue(captures._png_info(Path(entry['image_path']).read_bytes())['nonuniform'])
                    index = json.loads(Path(result['index']).read_text())
                    self.assertEqual(12.5,index['entries'][0]['requested_game_seconds'])
                    self.assertIn('../driver/game.log', Path(result['html']).read_text())

    def test_exact_named_png_is_preserved_and_not_reencoded(self):
        with tempfile.TemporaryDirectory() as directory:
            run, source = self.setup_run(directory)
            original = self.write_image(source,data=png(),suffix='.png')
            result = self.collect(run,request())
            self.assertTrue(result['passed'], result['errors'])
            self.assertEqual(str(original.resolve()),result['entries'][0]['original_source_path'])
            self.assertTrue(Path(result['entries'][0]['image_path']).is_relative_to(run/'captures/originals'))
            self.assertEqual(png(),Path(result['entries'][0]['image_path']).read_bytes())
            self.assertEqual(png(),original.read_bytes())

    def test_engine_zero_suffix_does_not_confuse_sequences_one_and_ten(self):
        for suffix in ('0.bmp','.bmp'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                run,source = self.setup_run(directory)
                for i in range(1,17):
                    self.write_image(source,index=i,suffix=suffix)
                result = self.collect(run,'\n'.join(request(index=i) for i in range(1,17)))
                self.assertTrue(result['passed'],result['errors'])
                self.assertEqual(16,len({e['source_path'] for e in result['entries']}))

    def test_missing_stale_uniform_or_duplicate_files_are_not_usable(self):
        for kind in ('missing','stale','uniform','duplicate','broken-png','bad-bmp'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                run,source = self.setup_run(directory)
                if kind == 'stale': self.write_image(source,modified=50)
                elif kind == 'uniform': self.write_image(source,data=bmp(uniform=True))
                elif kind == 'duplicate':
                    self.write_image(source)
                    self.write_image(source,prefix='KF-OUTPOST-PC-other-')
                elif kind == 'broken-png': self.write_image(source,data=png(broken_filter=True),suffix='.png')
                elif kind == 'bad-bmp': self.write_image(source,data=bmp()[:-1])
                result = self.collect(run,request())
                self.assertFalse(result['passed'])
                self.assertTrue(result['errors'])

    def test_uniform_png_and_oversized_collection_are_rejected(self):
        self.assertFalse(captures._png_info(png(uniform=True))['nonuniform'])
        with tempfile.TemporaryDirectory() as directory:
            run,source = self.setup_run(directory)
            self.write_image(source)
            with patch.object(captures,'MAX_BYTES',1):
                result = self.collect(run,request())
            self.assertFalse(result['passed'])
            self.assertIn('budget',' '.join(result['errors']))

    def test_missing_requests_invalid_run_bounds_and_malformed_pixels_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            run,source=self.setup_run(directory)
            self.write_image(source)
            self.assertFalse(self.collect(run,'no capture request')['passed'])
            result=captures.collect_captures(run,request(),started_unix=111,finished_unix=90)
            self.assertFalse(result['passed'])
            self.assertIn('time bounds',' '.join(result['errors']))
        for data in (png()[:-1], png()+b'trailing', bmp()[:20]):
            with self.subTest(data=data[:10]):
                with self.assertRaises(ValueError):
                    (captures._png_info if data.startswith(b'\x89PNG') else captures._bmp_info)(data)

    def test_unlogged_or_name_prefix_overlap_cannot_supply_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            run,source = self.setup_run(directory)
            self.write_image(source,index=2)
            result = self.collect(run,request())
            self.assertFalse(result['passed'])

    def test_conversion_is_idempotent_and_existing_different_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            run,source = self.setup_run(directory)
            self.write_image(source)
            first = self.collect(run,request())
            self.assertTrue(first['passed'])
            self.assertTrue(self.collect(run,request())['passed'])
            target=Path(first['entries'][0]['image_path'])
            target.write_bytes(b'previous-output')
            result = self.collect(run,request())
            self.assertFalse(result['passed'])
            self.assertEqual(b'previous-output',target.read_bytes())

    def test_capture_symlink_outside_run_cannot_be_read(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            run,source = self.setup_run(directory)
            external=Path(outside)/'external.bmp'
            external.write_bytes(bmp())
            try:
                (source/(name()+'0.bmp')).symlink_to(external)
            except OSError:
                self.skipTest('Windows symlink privilege unavailable')
            result=self.collect(run,request())
            self.assertFalse(result['passed'])
            self.assertEqual(bmp(),external.read_bytes())

    def test_explicit_external_root_copies_only_current_logged_images(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            run,owned=self.setup_run(directory)
            trusted=Path(external)
            platform=trusted/'Win64'
            platform.mkdir()
            original=self.write_image(platform,prefix='KF-OUTPOST-PC-18-12.45.30')
            stale=self.write_image(platform,index=2,modified=10)
            unrelated=platform/'unrelated.bmp'
            unrelated.write_bytes(bmp())
            before={p.name:p.read_bytes() for p in platform.iterdir()}
            self.assertFalse(self.collect(run,request())['passed'])
            result=captures.collect_captures(run,request(),started_unix=90,finished_unix=110,
                                             source_roots=[trusted,platform])
            self.assertTrue(result['passed'],result['errors'])
            entry=result['entries'][0]
            self.assertEqual(str(original.resolve()),entry['original_source_path'])
            self.assertTrue(Path(entry['source_path']).is_relative_to(run/'captures/originals'))
            self.assertEqual(entry['original_source_sha256'],entry['copied_sha256'])
            self.assertEqual(before,{p.name:p.read_bytes() for p in platform.iterdir()})
            self.assertEqual([name()+'.bmp'],[p.name for p in (run/'captures/originals').iterdir()])
            stale_result=captures.collect_captures(run,request()+'\n'+request(index=2),
                started_unix=90,finished_unix=110,source_roots=[trusted])
            self.assertFalse(stale_result['passed'])
            self.assertEqual('missing-or-stale',stale_result['entries'][1]['status'])

    def test_duplicate_trusted_roots_do_not_duplicate_the_same_file(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            run,owned=self.setup_run(directory)
            trusted=Path(external)
            self.write_image(trusted)
            result=captures.collect_captures(run,request(),started_unix=90,finished_unix=110,
                                             source_roots=[trusted,trusted])
            self.assertTrue(result['passed'],result['errors'])

    def test_external_link_refusal_without_requiring_windows_link_privilege(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            run,owned=self.setup_run(directory)
            trusted=Path(external)
            original=self.write_image(trusted)
            real_linked=captures._linked
            with patch.object(captures,'_linked',side_effect=lambda p:p==original or real_linked(p)):
                result=captures.collect_captures(run,request(),started_unix=90,finished_unix=110,
                                                 source_roots=[trusted])
            self.assertFalse(result['passed'])
            self.assertIn('trusted root',' '.join(result['errors']))
            self.assertFalse(list((run/'captures/originals').iterdir()))


if __name__ == '__main__':
    unittest.main()
