"""Explicit release download capabilities required by this repository."""
import portal_view_download_contract as contract
from unittest.mock import patch


class DownloadTests(contract.SourceContract, contract.StageContract, contract.PrepareContract, contract.DownloadFixture):
    def setUp(self):
        super().setUp()
        guard = patch.object(contract.cli, 'BASE', self.fixture.base)
        guard.start()
        self.addCleanup(guard.stop)
        (self.fixture.base / 'docker-images.env').write_text(
            'PORTAL_HYBRID_COMMAND_IMAGE=fixture/command:packaged\n'
            'PORTAL_HYBRID_QUERY_IMAGE=fixture/query:packaged\n')
