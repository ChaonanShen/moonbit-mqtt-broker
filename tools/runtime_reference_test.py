#!/usr/bin/env python3
import pathlib
import tempfile
import unittest
from unittest.mock import patch
from runtime_reference import parse_evidence, resolve, PROFILES


def evidence():
    lines = ['source_commit=' + 'a' * 40, 'exit_code=0', 'completed_at=2026-09-07T03:41:08Z']
    for index, profile in enumerate(PROFILES):
        lines.extend([f'runtime_{profile}=PASS', f'runtime_{profile}_image=sha256:' + str(index) * 64])
    return '\n'.join(lines)


class RuntimeReferenceTests(unittest.TestCase):
    def test_complete_success(self):
        self.assertEqual(parse_evidence(evidence())['exit_code'], '0')

    def test_failed_or_incomplete_run(self):
        for text in [evidence().replace('exit_code=0', 'exit_code=1'), evidence().replace('runtime_tls=PASS', 'runtime_tls=FAIL'), evidence().replace('completed_at=2026-09-07T03:41:08Z', '')]:
            with self.assertRaises(ValueError):
                parse_evidence(text)

    def test_duplicate_fields_rejected(self):
        with self.assertRaises(ValueError):
            parse_evidence(evidence() + '\nexit_code=0')

    def test_shell_text_is_not_an_image_reference(self):
        with self.assertRaises(ValueError):
            parse_evidence(evidence().replace('sha256:' + '0' * 64, 'image; echo injected'))

    def fixture(self, root):
        path = pathlib.Path(root) / 'test-results/distribution/reference'
        path.mkdir(parents=True)
        (path / 'evidence.txt').write_text(evidence())
        return path

    def test_changed_context_rejected_before_image_lookup(self):
        with tempfile.TemporaryDirectory() as root:
            reference = self.fixture(root)
            with patch('runtime_reference.output', side_effect=['new-tree', 'old-tree']) as calls:
                with self.assertRaises(ValueError):
                    resolve(root, reference, 'b' * 40)
                self.assertEqual(calls.call_count, 2)

    def test_platform_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            reference = self.fixture(root)
            with patch('runtime_reference.output', side_effect=['same-tree', 'same-tree', 'sha256:' + '0' * 64 + ' linux arm64']):
                with self.assertRaises(ValueError):
                    resolve(root, reference, 'b' * 40)

    def test_all_four_immutable_digests_returned(self):
        with tempfile.TemporaryDirectory() as root:
            reference = self.fixture(root)
            values = ['tree', 'tree'] + ['sha256:' + str(i) * 64 + ' linux amd64' for i in range(4)]
            with patch('runtime_reference.output', side_effect=values):
                result = resolve(root, reference, 'b' * 40)
                self.assertEqual(set(result['images']), set(PROFILES))

    def test_reference_must_stay_in_results_directory(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                resolve(root, pathlib.Path(root) / 'elsewhere', 'b' * 40)


if __name__ == '__main__':
    unittest.main()
